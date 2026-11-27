import Accelerate
import AVFoundation
import CryptoKit
import CoreVideo
import Foundation
import VideoToolbox

/// Which encoder a worker uses. The Mac has ONE hardware video encoder (about 230 fps at 1080p on an M4);
/// the software encoder runs on the CPU cores alongside it, so using both makes the export faster than either.
enum EncoderLane: String {
    case hardware, software
    case x264          // EXPERIMENT: libx264 through an external ffmpeg process (GPL, so never linked into the app)
}

struct HybridConfig {
    var hardwareLanes = 1
    var softwareLanes = 1
    var x264Lanes = 0
    var segmentSeconds = 8.0
    var verbose = false
    var useCache = true         // reuse already-encoded segments whose content hasn't changed
}

/// Draws frames (on the performance cores) and converts them to NV12, the encoders' native format.
/// Shared by every encoder lane.
final class FrameFactory: @unchecked Sendable {
    let song: Song
    let style: Style
    let width: Int, height: Int, fps: Int
    let queue = OperationQueue()
    private let scratch: ScratchPool
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    private let conversion: vImage_ARGBToYpCbCr
    /// One pool of frame buffers shared by every segment, so buffers are recycled instead of piling up.
    private let pool: CVPixelBufferPool

    init(song: Song, style: Style, width: Int, height: Int, fps: Int, workers: Int) {
        self.song = song; self.style = style; self.width = width; self.height = height; self.fps = fps
        scratch = ScratchPool(bytes: width * height * 4)
        var newPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary, &newPool)
        pool = newPool!
        queue.maxConcurrentOperationCount = workers
        queue.qualityOfService = .userInitiated
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        var info = vImage_ARGBToYpCbCr()
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &info,
                                                      kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        conversion = info
    }

    /// Draws one frame and returns it as an NV12 pixel buffer from the shared pool.
    func render(frame: Int) -> CVPixelBuffer? {
        var pbOpt: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOpt)
        guard let pb = pbOpt else { return nil }
        let memory = scratch.take()
        if let ctx = CGContext(data: memory, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                               space: colorSpace, bitmapInfo: bitmapInfo) {
            ctx.translateBy(x: 0, y: CGFloat(height))
            ctx.scaleBy(x: 1, y: -1)
            drawFrame(ctx, size: CGSize(width: width, height: height), videoTime: Double(frame) / Double(fps),
                      song: song, style: style)
        }
        CVPixelBufferLockBaseAddress(pb, [])
        var src = vImage_Buffer(data: memory, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var yPlane = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 0), height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 0))
        var cbcr = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(pb, 1), height: vImagePixelCount(height / 2),
                                 width: vImagePixelCount(width / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pb, 1))
        var conv = conversion
        var permute: [UInt8] = [3, 2, 1, 0]
        vImageConvert_ARGB8888To420Yp8_CbCr8(&src, &yPlane, &cbcr, &conv, &permute, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(pb, [])
        scratch.give(memory)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return pb
    }
}

/// Frames drawn out of order on several cores, handed to one encoder in order.
final class OrderedFrames: @unchecked Sendable {
    private let condition = NSCondition()
    private var frames: [Int: CVPixelBuffer] = [:]
    private var failure: String?

    func store(_ pb: CVPixelBuffer?, at index: Int) {
        condition.lock()
        if let pb { frames[index] = pb } else if failure == nil { failure = "could not draw a frame" }
        condition.broadcast(); condition.unlock()
    }
    func fail(_ message: String) { condition.lock(); if failure == nil { failure = message }; condition.broadcast(); condition.unlock() }
    var failureMessage: String? { condition.lock(); defer { condition.unlock() }; return failure }
    func take(_ index: Int) -> CVPixelBuffer? {
        condition.lock(); defer { condition.unlock() }
        while frames[index] == nil && failure == nil { condition.wait() }
        return failure != nil ? nil : frames.removeValue(forKey: index)
    }
}

/// Hands out segment numbers to whichever encoder lane is free next, so each lane naturally takes work in
/// proportion to how fast it is.
private final class SegmentQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var next = 0
    private let count: Int
    private(set) var cancelled = false
    private(set) var error: Error?
    init(count: Int) { self.count = count }
    func take() -> Int? {
        lock.lock(); defer { lock.unlock() }
        if cancelled || error != nil || next >= count { return nil }
        defer { next += 1 }
        return next
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func fail(_ e: Error) { lock.lock(); if error == nil { error = e }; lock.unlock() }
}

/// What an export did, so the app can learn how fast this Mac encodes and show better estimates.
struct ExportStats {
    var encodedFrames = 0         // frames actually encoded (not reused from the cache)
    var cachedFrames = 0
    var encodeSeconds = 0.0       // time spent encoding them
    var mode = ""
}

enum SegmentedExporter {
    /// Which encoders to use. H.264 can use the hardware encoder and the CPU together ("fast"); HEVC's software
    /// encoder is too slow to help, so HEVC uses the hardware alone. libx264 is never used by the app itself.
    static func plan(codec: VideoCodec, fast: Bool) -> HybridConfig {
        var c = HybridConfig()
        c.hardwareLanes = 1
        c.softwareLanes = (codec == .h264 && fast) ? 2 : 0
        return c
    }

    static func mode(for config: HybridConfig) -> String {
        config.x264Lanes > 0 ? "x264-experiment"
            : (config.hardwareLanes > 0 && config.softwareLanes > 0 ? "hybrid" : (config.hardwareLanes > 0 ? "hardware" : "software"))
    }

    /// Exports like `Exporter.export`, but splits the video into segments encoded at the same time by the hardware
    /// encoder and by software encoders, then joins them without re-encoding.
    @discardableResult
    static func export(song: Song, style: Style, audio: AudioSettings, options: ExportOptions, config: HybridConfig,
                       to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> ExportStats {
        let (width, height) = options.resolution.size
        let fps = options.fps
        let total = song.totalDuration
        let frameCount = options.frameCount(duration: total)
        let t0 = CFAbsoluteTimeGetCurrent()

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("fallingnotes-seg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Audio first (fast), encoded to AAC so it can be joined without re-encoding too.
        var audioURL: URL?
        if options.includeAudio {
            let caf = work.appendingPathComponent("audio.caf")
            try AudioPlayer(song: song, settings: audio).renderOffline(to: caf, duration: total)
            audioURL = try await encodeAudio(caf, to: work.appendingPathComponent("audio.m4a"))
            try? FileManager.default.removeItem(at: caf)
        }
        let tAudio = CFAbsoluteTimeGetCurrent()

        // Plan the segments.
        let segFrames = max(fps, Int(config.segmentSeconds * Double(fps)))
        let segments: [(start: Int, count: Int)] = stride(from: 0, to: frameCount, by: segFrames)
            .map { ($0, min(segFrames, frameCount - $0)) }
        let queue = SegmentQueue(count: segments.count)
        // Each segment is identified by everything that affects how it looks, so unchanged ones can be reused.
        let mode = mode(for: config)
        let keys = segments.map {
            SegmentCache.key(song: song, style: style, options: options, mode: mode, start: $0.start, count: $0.count)
        }
        let urls = SegmentURLs(count: segments.count)
        let factory = FrameFactory(song: song, style: style, width: width, height: height, fps: fps,
                                   workers: ExportOptions.drawWorkers)
        let done = ProgressCounter(total: frameCount, report: progress)
        let laneStats = LaneStats()

        // Start the encoder lanes.
        let group = DispatchGroup()
        var lanes: [EncoderLane] = Array(repeating: .hardware, count: config.hardwareLanes)
        lanes += Array(repeating: .software, count: config.softwareLanes)
        lanes += Array(repeating: .x264, count: config.x264Lanes)
        for (n, lane) in lanes.enumerated() {
            group.enter()
            let thread = Thread {
                defer { group.leave() }
                while let index = queue.take() {
                    let seg = segments[index]
                    let begun = CFAbsoluteTimeGetCurrent()
                    do {
                        if config.useCache, let cached = SegmentCache.lookup(keys[index]) {
                            urls.set(index, cached)
                            done.add(seg.count)
                            laneStats.recordCached(seg.count)
                            continue
                        }
                        if lane == .x264 {
                            try encodeSegmentX264(index: index, start: seg.start, count: seg.count, factory: factory,
                                                  options: options, directory: work, isCancelled: { queue.cancelled })
                        } else {
                            try encodeSegment(index: index, start: seg.start, count: seg.count, lane: lane, factory: factory,
                                              options: options, directory: work, isCancelled: { queue.cancelled })
                        }
                        let made = work.appendingPathComponent("seg_\(index).mp4")
                        urls.set(index, config.useCache ? try SegmentCache.store(made, key: keys[index]) : made)
                        done.add(seg.count)
                        laneStats.record(lane: "\(lane.rawValue)\(n)", frames: seg.count, seconds: CFAbsoluteTimeGetCurrent() - begun)
                    } catch { queue.fail(error) }
                }
            }
            thread.qualityOfService = .userInitiated
            thread.name = "encoder-\(lane.rawValue)-\(n)"
            thread.start()
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in group.notify(queue: .global()) { c.resume() } }
        } onCancel: { queue.cancel() }
        if queue.cancelled { throw CancellationError() }
        if let error = queue.error { throw error }
        let tEncode = CFAbsoluteTimeGetCurrent()
        let cachedNow = laneStats.cachedFrameCount

        // Join the segments (and the audio) without re-encoding.
        try await assemble(segmentURLs: urls.all, starts: segments.map(\.start), fps: fps, audio: audioURL, to: url)
        if config.useCache { SegmentCache.prune() }
        let tDone = CFAbsoluteTimeGetCurrent()
        progress(1)

        if config.verbose {
            print(String(format: "\n[hybrid] %d frames, %d segments of ~%.0fs | audio %.1fs | encode %.1fs (%.0f fps) | join %.1fs | total %.1fs",
                         frameCount, segments.count, config.segmentSeconds, tAudio - t0, tEncode - tAudio,
                         Double(frameCount) / (tEncode - tAudio), tDone - tEncode, tDone - t0))
            print(laneStats.summary)
        }
        return ExportStats(encodedFrames: frameCount - cachedNow, cachedFrames: cachedNow, encodeSeconds: tEncode - tAudio, mode: mode)
    }

    // MARK: One segment

    private static func encodeSegment(index: Int, start: Int, count: Int, lane: EncoderLane, factory: FrameFactory,
                                      options: ExportOptions, directory: URL, isCancelled: @escaping @Sendable () -> Bool) throws {
        let fps = factory.fps
        let url = directory.appendingPathComponent("seg_\(index).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        var spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: lane == .hardware]
        if lane == .hardware { spec[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String] = true }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: options.videoBitrate,
            AVVideoMaxKeyFrameIntervalKey: fps * 2,
            // No B-frames: every frame's decode time equals its display time, so segments join cleanly.
            AVVideoAllowFrameReorderingKey: false,
        ]
        if options.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: options.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: factory.width, AVVideoHeightKey: factory.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: spec,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: factory.width, kCVPixelBufferHeightKey as String: factory.height,
        ])
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "could not start writing a segment")
        }
        writer.startSession(atSourceTime: .zero)

        // Draw the segment's frames ahead of the encoder on the shared drawing cores.
        let frames = OrderedFrames()
        let window = 10
        let slots = DispatchSemaphore(value: window)
        DispatchQueue.global(qos: .userInitiated).async {
            for frame in start..<(start + count) {
                slots.wait()
                if frames.failureMessage != nil { break }
                factory.queue.addOperation { frames.store(factory.render(frame: frame), at: frame) }
            }
        }

        let done = DispatchGroup()
        let feed = DispatchQueue(label: "fallingnotes.segment.\(index)", qos: .userInitiated)
        var next = 0
        var finished = false
        done.enter()
        // Weak references: the input keeps this callback alive, so strong ones would form a cycle and every
        // segment's writer, encoder session and buffer pool would stay in memory for the rest of the export.
        input.requestMediaDataWhenReady(on: feed) { [weak input, weak adaptor, weak writer] in
            guard let input, let adaptor else { return }
            while input.isReadyForMoreMediaData, !finished {
                if isCancelled() { frames.fail("cancelled") }          // stop promptly instead of finishing the segment
                if next >= count { input.markAsFinished(); finished = true; done.leave(); return }
                guard let pb = frames.take(start + next) else { input.markAsFinished(); finished = true; done.leave(); return }
                if !adaptor.append(pb, withPresentationTime: CMTime(value: Int64(next), timescale: Int32(fps))) {
                    frames.fail(writer?.error?.localizedDescription ?? "could not append a frame")
                }
                slots.signal()
                next += 1
            }
        }
        done.wait()
        if let message = frames.failureMessage {
            for _ in 0..<(window + 1) { slots.signal() }
            writer.cancelWriting()
            throw ExportError.writer(message)
        }
        let finishedSignal = DispatchSemaphore(value: 0)
        writer.finishWriting { finishedSignal.signal() }
        finishedSignal.wait()
        guard writer.status == .completed else {
            throw ExportError.writer(writer.error?.localizedDescription ?? "segment \(index) failed")
        }
    }

    // MARK: EXPERIMENT: libx264 lane (external ffmpeg process)

    private static func encodeSegmentX264(index: Int, start: Int, count: Int, factory: FrameFactory,
                                          options: ExportOptions, directory: URL, isCancelled: @escaping @Sendable () -> Bool) throws {
        let fps = factory.fps, w = factory.width, h = factory.height
        let url = directory.appendingPathComponent("seg_\(index).mp4")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        // The input's colour range and matrix are declared BEFORE -i; otherwise ffmpeg guesses and shifts the brightness.
        proc.arguments = ["-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "nv12", "-color_range", "tv", "-colorspace", "bt709",
                          "-s", "\(w)x\(h)", "-r", "\(fps)", "-i", "-",
                          "-c:v", "libx264", "-preset", "veryfast", "-b:v", "\(options.videoBitrate)", "-bf", "0", "-g", "\(fps * 2)",
                          "-threads", "3", "-pix_fmt", "yuv420p", "-profile:v", "high",
                          "-x264-params", "colorprim=bt709:transfer=bt709:colormatrix=bt709:range=tv",
                          "-movflags", "+faststart", url.path]
        let pipe = Pipe()
        proc.standardInput = pipe
        try proc.run()

        let frames = OrderedFrames()
        let window = 10
        let slots = DispatchSemaphore(value: window)
        DispatchQueue.global(qos: .userInitiated).async {
            for frame in start..<(start + count) {
                slots.wait()
                if frames.failureMessage != nil { break }
                factory.queue.addOperation { frames.store(factory.render(frame: frame), at: frame) }
            }
        }
        let out = pipe.fileHandleForWriting
        var packed = Data(count: w * h * 3 / 2)
        for i in 0..<count {
            if isCancelled() { frames.fail("cancelled") }
            guard let pb = frames.take(start + i) else { break }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            packed.withUnsafeMutableBytes { dst in
                let base = dst.baseAddress!
                for plane in 0..<2 {
                    let rows = CVPixelBufferGetHeightOfPlane(pb, plane), rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pb, plane)
                    let src = CVPixelBufferGetBaseAddressOfPlane(pb, plane)!
                    let offset = plane == 0 ? 0 : w * h
                    for y in 0..<rows { memcpy(base + offset + y * w, src + y * rowBytes, w) }
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            try out.write(contentsOf: packed)
            slots.signal()
        }
        try out.close()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { throw ExportError.writer("ffmpeg/x264 failed on segment \(index)") }
    }

    // MARK: Audio and joining

    private static func encodeAudio(_ caf: URL, to m4a: URL) async throws -> URL {
        try? FileManager.default.removeItem(at: m4a)
        let writer = try AVAssetWriter(outputURL: m4a, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: ExportOptions.audioBitrate,
        ])
        writer.add(input)
        let asset = AVURLAsset(url: caf)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ExportError.writer("no audio track") }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 2,
        ])
        reader.add(out)
        guard writer.startWriting() else { throw ExportError.writer("could not start audio writer") }
        writer.startSession(atSourceTime: .zero)
        reader.startReading()
        let queue = DispatchQueue(label: "fallingnotes.audio.encode")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData {
                    if let sample = out.copyNextSampleBuffer() { input.append(sample) } else { input.markAsFinished(); c.resume(); return }
                }
            }
        }
        await writer.finishWriting()
        return m4a
    }

    /// Lines the segments up on one timeline and writes them out by copying the compressed data (no re-encode).
    private static func assemble(segmentURLs: [URL], starts: [Int], fps: Int, audio: URL?, to url: URL) async throws {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.writer("could not create the video track") }
        for (i, segURL) in segmentURLs.enumerated() {
            let asset = AVURLAsset(url: segURL)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ExportError.writer("segment \(i) has no video") }
            let duration = try await asset.load(.duration)
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track,
                                           at: CMTime(value: Int64(starts[i]), timescale: Int32(fps)))
        }
        if let audio {
            let asset = AVURLAsset(url: audio)
            if let track = try await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: track, at: .zero)
            }
        }
        try? FileManager.default.removeItem(at: url)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw ExportError.writer("could not create the export session")
        }
        export.outputURL = url
        export.outputFileType = url.pathExtension.lowercased() == "mov" ? .mov : .mp4
        export.shouldOptimizeForNetworkUse = true
        await export.export()
        guard export.status == .completed else {
            throw ExportError.writer(export.error?.localizedDescription ?? "joining the segments failed")
        }
    }
}

private final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private let total: Int
    private let report: @Sendable (Double) -> Void
    init(total: Int, report: @escaping @Sendable (Double) -> Void) { self.total = total; self.report = report }
    func add(_ n: Int) { lock.lock(); frames += n; let f = frames; lock.unlock(); report(min(0.99, Double(f) / Double(total))) }
}

private final class LaneStats: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [String: Int] = [:], seconds: [String: Double] = [:], segments: [String: Int] = [:]
    private var cachedFrames = 0, cachedSegments = 0
    var cachedFrameCount: Int { lock.lock(); defer { lock.unlock() }; return cachedFrames }
    func recordCached(_ n: Int) { lock.lock(); cachedFrames += n; cachedSegments += 1; lock.unlock() }
    func record(lane: String, frames n: Int, seconds s: Double) {
        lock.lock(); frames[lane, default: 0] += n; seconds[lane, default: 0] += s; segments[lane, default: 0] += 1; lock.unlock()
    }
    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let cached = cachedSegments > 0 ? ["  reused from cache: \(cachedSegments) segments (\(cachedFrames) frames)"] : []
        let lanes = frames.keys.sorted().map { k in
            String(format: "  lane %@: %d segments, %d frames, busy %.1fs (%.0f fps while working)",
                   k, segments[k] ?? 0, frames[k] ?? 0, seconds[k] ?? 0, Double(frames[k] ?? 0) / max(seconds[k] ?? 1, 0.001))
        }
        return (cached + lanes).joined(separator: "\n")
    }
}

/// The finished segment files, filled in as the lanes complete them.
private final class SegmentURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL?]
    init(count: Int) { urls = Array(repeating: nil, count: count) }
    func set(_ i: Int, _ url: URL) { lock.lock(); urls[i] = url; lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls.compactMap { $0 } }
}

/// Encoded segments kept on disk (in ~/Library/Caches) so exporting again with unchanged visuals is nearly instant.
enum SegmentCache {
    /// Bump when the drawing code changes in a way that alters frames, so old segments are not reused.
    static let renderRevision = 1
    static let maxBytes: Int64 = 2 * 1024 * 1024 * 1024

    static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FallingNotes/Segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Identifies a segment by everything that changes how its frames look. Audio is deliberately not included.
    static func key(song: Song, style: Style, options: ExportOptions, mode: String, start: Int, count: Int) -> String {
        var h = SHA256()
        func put(_ x: Double) { var v = x.bitPattern; withUnsafeBytes(of: &v) { h.update(bufferPointer: $0) } }
        func put(_ x: Int) { put(Double(x)) }
        func put(_ s: String) { h.update(data: Data(s.utf8)) }
        func put(_ c: CGColor) { (c.components ?? []).forEach { put(Double($0)) } }

        put("fn-segment"); put(renderRevision)
        put(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
        put(mode)
        let (w, hgt) = options.resolution.size
        put(w); put(hgt); put(options.fps); put(options.codec.rawValue); put(options.videoBitrate)
        put(start); put(count)
        put(style.fallSeconds); put(style.background); put(style.fullKeyboard ? 1 : 0); put(style.glow ? 1 : 0)
        put(Double(style.faintOpacity))
        let layout = KeyLayout(song: song, fullKeyboard: style.fullKeyboard, width: CGFloat(w))
        put(layout.lo); put(layout.hi)

        // The notes that can appear in this segment, with how each one is drawn.
        let first = Double(start) / Double(options.fps) - Song.leadIn
        let last = Double(start + count - 1) / Double(options.fps) - Song.leadIn
        for n in song.notes where n.end >= first && n.start <= last + style.fallSeconds {
            if style.hidden.contains(n.part) || !layout.contains(n.pitch) { continue }   // not drawn: doesn't matter
            put(n.pitch); put(n.start); put(n.end); put(style.color(n.part))
            put(style.faint.contains(n.part) ? 1 : 0)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func lookup(_ key: String) -> URL? {
        let url = directory.appendingPathComponent("\(key).mp4")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int, size > 0 else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)   // recently used
        return url
    }

    /// Moves a finished segment into the cache (written under a temporary name first, so a partial file is never reused).
    static func store(_ file: URL, key: String) throws -> URL {
        let final = directory.appendingPathComponent("\(key).mp4")
        let temporary = directory.appendingPathComponent("\(key).partial-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: file, to: temporary)
        try? FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: temporary, to: final)
        return final
    }

    /// Deletes the least recently used segments once the cache is over its size limit.
    static func prune() {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { u -> (URL, Date, Int64)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, v.contentModificationDate ?? .distantPast, Int64(v.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        entries.sort { $0.1 < $1.1 }
        for (u, _, size) in entries where total > maxBytes {
            try? FileManager.default.removeItem(at: u)
            total -= size
        }
    }

    static var sizeOnDisk: Int64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        files.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
