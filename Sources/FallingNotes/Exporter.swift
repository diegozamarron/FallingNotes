// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import Accelerate
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import VideoToolbox

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
    var bitrateScale = 1.0          // testing: multiplies the target bitrate

    /// HEVC reaches similar quality at about half the bitrate, which is what makes its files smaller.
    var videoBitrate: Int {
        let (w, h) = resolution.size
        return Int(Double(w * h) * Double(fps) * (codec == .hevc ? 0.08 : 0.15) * bitrateScale)
    }
    static let audioBitrate = 192_000

    /// How many frames to draw at the same time: one per performance core (the Mac's fast cores). More threads
    /// would only pull in the slower efficiency cores and hold more frames in memory.
    static var drawWorkers: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.logicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)   // Intel Macs: no performance/efficiency split
    }

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
            try AudioPlayer.renderAudio(song: song, settings: audio, to: audioURL, duration: total)
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
            AVVideoEncoderSpecificationKey: [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
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

        // 3. Draw frames on several performance cores and hand them to the encoder, in order, the moment it asks for more.
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let size = CGSize(width: width, height: height)
        let state = ExportState()
        let scratch = ScratchPool(bytes: width * height * 4)
        // RGB -> video-range YCbCr using the HD (BT.709) matrix.
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var yuvConversion = vImage_ARGBToYpCbCr()
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &yuvConversion,
                                                      kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        // Drawing runs on the performance cores only, and only a few frames are held in memory at once.
        let workers = ExportOptions.drawWorkers
        let frameBytes = width * height * 4
        let window = max(workers + 2, min(workers * 3, (160 * 1024 * 1024) / frameBytes))
        let slots = DispatchSemaphore(value: window)
        let done = DispatchGroup()

        // Producer: starts a draw job for each frame, never more than `window` ahead of what the encoder has taken.
        let producer = DispatchQueue(label: "fallingnotes.producer", qos: .userInitiated)
        let drawers = OperationQueue()
        drawers.maxConcurrentOperationCount = workers      // never more than this many frames drawn at once
        drawers.qualityOfService = .userInitiated          // steers the work onto the performance cores
        producer.async {
            for frame in 0..<frameCount {
                slots.wait()
                if state.isStopped { break }
                drawers.addOperation {
                    var pbOpt: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
                    guard let pb = pbOpt else { state.fail("could not allocate a frame"); return }
                    // Draw with Core Graphics into plain BGRA memory...
                    let scratchMemory = scratch.take()
                    if let ctx = CGContext(data: scratchMemory, width: width, height: height,
                                           bitsPerComponent: 8, bytesPerRow: width * 4,
                                           space: colorSpace, bitmapInfo: bitmapInfo) {
                        ctx.translateBy(x: 0, y: CGFloat(height))
                        ctx.scaleBy(x: 1, y: -1)
                        drawFrame(ctx, size: size, videoTime: Double(frame) / Double(fps), song: song, style: style)
                    }
                    // ...then convert to NV12 here, on this core, so the encoder gets frames in its native format.
                    CVPixelBufferLockBaseAddress(pb, [])
                    var src = vImage_Buffer(data: scratchMemory, height: vImagePixelCount(height),
                                            width: vImagePixelCount(width), rowBytes: width * 4)
                    var yPlane = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 0),
                                               height: vImagePixelCount(height), width: vImagePixelCount(width),
                                               rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
                    var cbcrPlane = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 1),
                                                  height: vImagePixelCount(height / 2), width: vImagePixelCount(width / 2),
                                                  rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
                    var conversion = yuvConversion
                    var permute: [UInt8] = [3, 2, 1, 0]               // memory order is B,G,R,A
                    vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &yPlane, &cbcrPlane, &conversion, &permute,
                                                         vImage_Flags(kvImageNoFlags))
                    CVPixelBufferUnlockBaseAddress(pb, [])
                    scratch.give(scratchMemory)
                    CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
                    CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
                    state.store(pb, at: frame)
                }
            }
        }

        // Video: the encoder calls this whenever it can take more frames.
        let videoQueue = DispatchQueue(label: "fallingnotes.video", qos: .userInitiated)
        var nextFrame = 0
        var videoFinished = false
        done.enter()
        videoInput.requestMediaDataWhenReady(on: videoQueue) {
            while videoInput.isReadyForMoreMediaData, !videoFinished {
                if nextFrame >= frameCount {
                    videoInput.markAsFinished(); videoFinished = true; done.leave(); return
                }
                guard let pb = state.take(nextFrame) else {          // stopped or failed
                    videoInput.markAsFinished(); videoFinished = true; done.leave(); return
                }
                let time = CMTime(value: Int64(nextFrame), timescale: Int32(fps))
                if !adaptor.append(pb, withPresentationTime: time) {
                    state.fail(writer.error?.localizedDescription ?? "could not append a frame")
                }
                slots.signal()
                nextFrame += 1
                if nextFrame % 15 == 0 { progress(Double(nextFrame) / Double(frameCount)) }
            }
        }

        // Audio: the same idea, on its own queue.
        if let ain = audioInput, let out = audioOutput {
            let audioQueue = DispatchQueue(label: "fallingnotes.audio", qos: .userInitiated)
            var audioFinished = false
            done.enter()
            ain.requestMediaDataWhenReady(on: audioQueue) {
                while ain.isReadyForMoreMediaData, !audioFinished {
                    if state.isStopped { ain.markAsFinished(); audioFinished = true; done.leave(); return }
                    if let sample = out.copyNextSampleBuffer() {
                        if !ain.append(sample) {
                            state.fail(writer.error?.localizedDescription ?? "could not append audio")
                        }
                    } else {
                        ain.markAsFinished(); audioFinished = true; done.leave(); return
                    }
                }
            }
        }

        // Wait for both to finish, and stop everything if the export is cancelled.
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                done.notify(queue: .global()) { continuation.resume() }
            }
        } onCancel: {
            state.cancel()
            for _ in 0..<(window + 1) { slots.signal() }      // let a waiting producer notice and stop
        }

        if state.wasCancelled {
            writer.cancelWriting()
            audioReader?.cancelReading()
            throw CancellationError()
        }
        if let message = state.failureMessage {
            writer.cancelWriting()
            audioReader?.cancelReading()
            throw ExportError.writer(message)
        }

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "unknown error")
        }
        progress(1)
    }
}

/// Frames drawn on other threads waiting for the encoder, plus the stop/failure flags they share.
private final class ExportState: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [Int: CVPixelBuffer] = [:]
    private var failure: String?
    private var cancelled = false

    var isStopped: Bool { condition.lock(); defer { condition.unlock() }; return failure != nil || cancelled }
    var wasCancelled: Bool { condition.lock(); defer { condition.unlock() }; return cancelled }
    var failureMessage: String? { condition.lock(); defer { condition.unlock() }; return failure }

    func store(_ pb: CVPixelBuffer, at index: Int) {
        condition.lock(); frames[index] = pb; condition.broadcast(); condition.unlock()
    }

    /// Waits for frame `index` to be drawn. Returns nil if the export was cancelled or failed meanwhile.
    func take(_ index: Int) -> CVPixelBuffer? {
        condition.lock(); defer { condition.unlock() }
        while frames[index] == nil && failure == nil && !cancelled { condition.wait() }
        if failure != nil || cancelled { return nil }
        return frames.removeValue(forKey: index)
    }

    func fail(_ message: String) {
        condition.lock(); if failure == nil { failure = message }; condition.broadcast(); condition.unlock()
    }

    func cancel() {
        condition.lock(); cancelled = true; condition.broadcast(); condition.unlock()
    }
}

/// Reusable BGRA memory for drawing (one block per frame being drawn), so frames aren't allocated over and over.
final class ScratchPool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [UnsafeMutableRawPointer] = []
    private let bytes: Int
    init(bytes: Int) { self.bytes = bytes }
    func take() -> UnsafeMutableRawPointer {
        lock.lock(); defer { lock.unlock() }
        return free.popLast() ?? UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
    }
    func give(_ memory: UnsafeMutableRawPointer) { lock.lock(); free.append(memory); lock.unlock() }
    deinit { free.forEach { $0.deallocate() } }
}
