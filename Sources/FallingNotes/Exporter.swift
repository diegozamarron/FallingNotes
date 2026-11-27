import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

enum Resolution: String, CaseIterable, Identifiable {
    case p720, p1080, p2160, vertical
    var id: String { rawValue }
    var label: String {
        switch self {
        case .p720: return "1280 × 720"
        case .p1080: return "1920 × 1080"
        case .p2160: return "3840 × 2160 (4K)"
        case .vertical: return "1080 × 1920 (vertical)"
        }
    }
    var size: (width: Int, height: Int) {
        switch self {
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        case .p2160: return (3840, 2160)
        case .vertical: return (1080, 1920)
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var label: String { self == .h264 ? "H.264 (most compatible)" : "HEVC (smaller files)" }
}

struct ExportOptions {
    var resolution: Resolution = .p1080
    var fps: Int = 30
    var codec: VideoCodec = .h264
    var includeAudio = true

    /// HEVC reaches similar quality at about half the bitrate, which is what makes its files smaller.
    var videoBitrate: Int {
        let (w, h) = resolution.size
        return Int(Double(w * h) * Double(fps) * (codec == .hevc ? 0.08 : 0.15))
    }
    static let audioBitrate = 192_000

    func frameCount(duration: Double) -> Int { Int(ceil(duration * Double(fps))) }

    func estimatedBytes(duration: Double) -> Int {
        Int(Double(videoBitrate + (includeAudio ? ExportOptions.audioBitrate : 0)) / 8 * duration)
    }
}

enum ExportError: LocalizedError {
    case writer(String)
    var errorDescription: String? {
        switch self { case .writer(let m): return "Export failed: \(m)" }
    }
}

enum Exporter {
    static func export(song: Song, style: Style, audio: AudioSettings, options: ExportOptions, to url: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let (width, height) = options.resolution.size
        let fps = options.fps
        let total = song.totalDuration
        let frameCount = options.frameCount(duration: total)

        // 1. Render the audio first (faster than real time).
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fallingnotes-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: audioURL) }
        if options.includeAudio {
            try AudioPlayer(song: song, settings: audio).renderOffline(to: audioURL, duration: total)
        }

        // 2. Set up the writer.
        try? FileManager.default.removeItem(at: url)
        let fileType: AVFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
        ]
        if options.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        var audioReader: AVAssetReader?
        var audioOutput: AVAssetReaderTrackOutput?
        if options.includeAudio {
            let ain = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportOptions.audioBitrate,
            ])
            ain.expectsMediaDataInRealTime = false
            writer.add(ain)
            audioInput = ain

            let asset = AVURLAsset(url: audioURL)
            let reader = try AVAssetReader(asset: asset)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ExportError.writer("rendered audio has no track")
            }
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: 2,
            ])
            reader.add(out)
            audioReader = reader
            audioOutput = out
        }

        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "could not start writing")
        }
        writer.startSession(atSourceTime: .zero)
        audioReader?.startReading()
        guard let pool = adaptor.pixelBufferPool else { throw ExportError.writer("no pixel buffer pool") }

        // 3. Interleave video frames and audio samples.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let size = CGSize(width: width, height: height)
        var frame = 0
        var videoDone = false
        var audioDone = audioInput == nil

        while !(videoDone && audioDone) {
            if Task.isCancelled {
                writer.cancelWriting()
                audioReader?.cancelReading()
                throw CancellationError()
            }
            var progressed = false

            if !videoDone, videoInput.isReadyForMoreMediaData {
                if frame < frameCount {
                    var pbOpt: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
                    guard let pb = pbOpt else { throw ExportError.writer("could not allocate frame") }
                    CVPixelBufferLockBaseAddress(pb, [])
                    if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                           space: colorSpace, bitmapInfo: bitmapInfo) {
                        ctx.translateBy(x: 0, y: CGFloat(height))
                        ctx.scaleBy(x: 1, y: -1)
                        drawFrame(ctx, size: size, videoTime: Double(frame) / Double(fps), song: song, style: style)
                    }
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    let time = CMTime(value: Int64(frame), timescale: Int32(fps))
                    if !adaptor.append(pb, withPresentationTime: time) {
                        throw ExportError.writer(writer.error?.localizedDescription ?? "could not append frame")
                    }
                    frame += 1
                    if frame % 15 == 0 { progress(Double(frame) / Double(frameCount)) }
                } else {
                    videoInput.markAsFinished()
                    videoDone = true
                }
                progressed = true
            }

            if !audioDone, let ain = audioInput, let out = audioOutput, ain.isReadyForMoreMediaData {
                if let sample = out.copyNextSampleBuffer() {
                    if !ain.append(sample) {
                        throw ExportError.writer(writer.error?.localizedDescription ?? "could not append audio")
                    }
                } else {
                    ain.markAsFinished()
                    audioDone = true
                }
                progressed = true
            }

            if !progressed { try await Task.sleep(nanoseconds: 1_000_000) }
            else if frame % 8 == 0 { await Task.yield() }
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }
}
