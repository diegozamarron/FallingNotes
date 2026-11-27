import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 75 -> "1:15", 3725 -> "1:02:05"
func formatClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

/// How an instrument's notes appear in the video.
enum PartLook: String, CaseIterable, Identifiable {
    case shown, faint, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .shown: return "Visible"
        case .faint: return "Faint (background)"
        case .hidden: return "Hidden"
        }
    }
    var icon: String {
        switch self {
        case .shown: return "eye"
        case .faint: return "eye.circle"
        case .hidden: return "eye.slash"
        }
    }
}

/// Per-instrument settings the user can change.
struct PartState {
    var program: Int
    var look: PartLook
    var audible: Bool
    var volume: Double = 1     // 0...1.5
    var color: Color
}

@MainActor
final class Transport: ObservableObject {
    @Published var isPlaying = false
    @Published var scrubTime = 0.0
}

@MainActor
final class AppModel: ObservableObject {
    @Published var song: Song?
    @Published var parts: [PartState] = []
    @Published var soundFont: URL?
    @Published var errorMessage: String?

    // Organising instruments (see Groups.swift)
    @Published var groups: [PartGroup] = []
    @Published var selection: Set<Int> = []

    // Look
    @Published var background = Color(red: 0.05, green: 0.06, blue: 0.09)
    @Published var fallSeconds = 2.0
    @Published var fullKeyboard = true
    @Published var glow = true
    @Published var faintOpacity = 0.3

    // Export
    @Published var resolution: Resolution = .p1080
    @Published var fps = 30
    @Published var codec: VideoCodec = .h264
    @Published var includeAudio = true
    /// Use the hardware encoder and the CPU together (about twice as fast for H.264). Off = one encoder, one stream.
    @Published var fastEncoding = true
    @Published var cacheBytes: Int64 = 0
    @Published var exportProgress: Double?
    @Published var exportStart: Date?          // when the export began (includes preparing the audio)
    @Published var exportVideoStart: Date?     // when the first video frames were done; used for the time estimate
    @Published var lastExport: URL?
    @Published var lastExportSummary: String?

    var exportOptions: ExportOptions {
        ExportOptions(resolution: resolution, fps: fps, codec: codec, includeAudio: includeAudio)
    }

    // Transport. Kept in its own object so the 30 Hz position updates only redraw the preview and the
    // slider, not the whole settings panel.
    let transport = Transport()
    var isPlaying: Bool {
        get { transport.isPlaying }
        set { transport.isPlaying = newValue }
    }
    /// Position on the video timeline.
    var scrubTime: Double {
        get { transport.scrubTime }
        set { transport.scrubTime = newValue }
    }

    private var player: AudioPlayer?
    private var ticker: Timer?
    private var exportTask: Task<Void, Never>?

    var style: Style {
        var s = Style()
        s.fallSeconds = fallSeconds
        s.background = NSColor(background).usingColorSpace(.sRGB)?.cgColor ?? s.background
        s.trackColors = parts.map { NSColor($0.color).usingColorSpace(.sRGB)?.cgColor ?? Palette.defaults[0] }
        s.fullKeyboard = fullKeyboard
        s.glow = glow
        s.hidden = Set(parts.indices.filter { parts[$0].look == .hidden })
        s.faint = Set(parts.indices.filter { parts[$0].look == .faint })
        s.faintOpacity = CGFloat(faintOpacity)
        return s
    }

    var audioSettings: AudioSettings {
        AudioSettings(soundFont: soundFont, programs: parts.map(\.program), audible: parts.map(\.audible),
                      volumes: parts.map { Float($0.volume) })
    }

    var total: Double { song?.totalDuration ?? 0 }

    /// Current position for drawing; reads the audio clock while playing.
    func videoTime() -> Double {
        if isPlaying, let player { return min(player.position, total) }
        return scrubTime
    }

    // MARK: Loading

    func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mid", "midi"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { load(url: url) }
    }

    func load(url: URL) {
        do {
            let s = try MIDIParser.load(url: url)
            pause()
            let newParts = s.parts.enumerated().map { (i, p) in
                PartState(program: p.program,
                          look: p.isDrums ? .hidden : .shown,   // drums have no sensible place on a keyboard
                          audible: true,
                          color: Color(cgColor: Palette.defaults[i % Palette.defaults.count]))
            }
            let settings = AudioSettings(soundFont: soundFont, programs: newParts.map(\.program),
                                         audible: newParts.map(\.audible))
            let p: AudioPlayer
            do { p = try AudioPlayer(song: s, settings: settings) }
            catch {
                // A custom soundfont that can't be loaded shouldn't block opening a song.
                soundFont = nil
                var fallback = settings
                fallback.soundFont = nil
                p = try AudioPlayer(song: s, settings: fallback)
                errorMessage = "The soundfont couldn't be loaded, so the built-in sounds are being used."
            }
            player = p
            parts = newParts
            groups = []
            selection = []
            song = s
            refreshCacheSize()
            scrubTime = 0
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Instruments

    func setLook(_ i: Int, _ look: PartLook) {
        guard parts.indices.contains(i) else { return }
        parts[i].look = look
    }

    func setVolume(_ i: Int, _ volume: Double) {
        guard parts.indices.contains(i) else { return }
        parts[i].volume = volume
        player?.setVolume(i, Float(volume))
    }

    func setAudible(_ i: Int, _ on: Bool) {
        guard parts.indices.contains(i) else { return }
        parts[i].audible = on
        player?.setAudible(i, on)
    }

    func setProgram(_ i: Int, _ program: Int) {
        guard parts.indices.contains(i) else { return }
        let old = parts[i].program
        parts[i].program = program
        do { try player?.setProgram(i, program) } catch {
            parts[i].program = old
            errorMessage = "That instrument isn't available in the current soundfont."
        }
    }

    func resetInstruments() {
        guard let song else { return }
        for i in parts.indices where parts[i].program != song.parts[i].program {
            setProgram(i, song.parts[i].program)
        }
    }

    func chooseSoundFont() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["sf2", "dls", "sf3"].compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = "Choose a SoundFont (.sf2) or DLS (.dls) file"
        if panel.runModal() == .OK, let url = panel.url { setSoundFont(url) }
    }

    func setSoundFont(_ url: URL?) {
        do {
            try player?.setSoundFont(url)
            soundFont = url
        } catch {
            errorMessage = "Couldn't load that soundfont: \(error.localizedDescription)"
        }
    }

    // MARK: Transport

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let player, song != nil else { return }
        if scrubTime >= total - 0.05 { scrubTime = 0 }
        player.position = scrubTime
        do { try player.play() } catch { errorMessage = error.localizedDescription; return }
        isPlaying = true
        // Only drives the slider and time label (the preview reads the audio clock directly each frame),
        // so a low rate is plenty and keeps SwiftUI from re-laying out the window constantly.
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                let t = player.position
                if t >= self.total {
                    self.pause()
                    self.scrubTime = self.total
                } else {
                    self.scrubTime = t
                }
            }
        }
    }

    func pause() {
        guard isPlaying else { return }
        scrubTime = min(player?.position ?? scrubTime, total)
        player?.pause()
        isPlaying = false
        ticker?.invalidate()
        ticker = nil
    }

    func seek(to t: Double) {
        scrubTime = max(0, min(t, total))
        if isPlaying { player?.position = scrubTime }
    }

    // MARK: Export

    /// Asks where to save (unless `destination` is given, which the test hook uses) and renders the video.
    func startExport(to destination: URL? = nil) {
        guard let song, exportProgress == nil else { return }
        pause()
        let url: URL
        if let destination {
            url = destination
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
            panel.nameFieldStringValue = song.url.deletingPathExtension().lastPathComponent + ".mp4"
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            url = chosen
        }

        let options = exportOptions
        let style = self.style
        let audio = self.audioSettings
        let model = self
        exportProgress = 0
        exportStart = Date()
        exportVideoStart = nil
        lastExport = nil
        lastExportSummary = nil
        // Detached so the render loop runs on a background thread. A plain `Task {}` here would inherit the main
        // actor and freeze the whole window for the length of the export.
        let config = SegmentedExporter.plan(codec: options.codec, fast: fastEncoding)
        exportTask = Task.detached(priority: .userInitiated) {
            let report: @Sendable (Double) -> Void = { p in Task { @MainActor in model.exportUpdate(p) } }
            do {
                do {
                    let stats = try await SegmentedExporter.export(song: song, style: style, audio: audio, options: options,
                                                                   config: config, to: url, progress: report)
                    await MainActor.run { model.learnSpeed(stats, options: options) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // If the segmented path fails for any reason, fall back to the plain single-encoder export.
                    try await Exporter.export(song: song, style: style, audio: audio, options: options, to: url, progress: report)
                }
                await MainActor.run { model.exportFinished(url: url) }
            } catch is CancellationError {
                await MainActor.run { model.exportEnded() }   // cancelled by the user
            } catch {
                let message = error.localizedDescription
                await MainActor.run { model.errorMessage = message; model.exportEnded() }
            }
        }
    }

    // MARK: Render-time estimate and cache

    /// Megapixels per second this Mac has encoded at (remembered from earlier exports), or a typical M-series figure.
    func throughput(for mode: String) -> Double {
        let saved = UserDefaults.standard.double(forKey: "throughput.\(mode)")
        if saved > 50 { return saved }
        return mode == "hybrid" ? 800 : 450
    }

    func learnSpeed(_ stats: ExportStats, options: ExportOptions) {
        guard stats.encodedFrames > 600, stats.encodeSeconds > 2 else { return }     // too little real encoding to learn from
        let (w, h) = options.resolution.size
        let rate = Double(stats.encodedFrames) * Double(w * h) / 1e6 / stats.encodeSeconds
        let old = UserDefaults.standard.double(forKey: "throughput.\(stats.mode)")
        UserDefaults.standard.set(old > 50 ? (old + rate) / 2 : rate, forKey: "throughput.\(stats.mode)")
    }

    /// About how long rendering will take, not counting segments that may be reused from the cache.
    func estimatedRenderSeconds() -> Double? {
        guard let song else { return nil }
        let options = exportOptions
        let (w, h) = options.resolution.size
        let mode = SegmentedExporter.mode(for: SegmentedExporter.plan(codec: options.codec, fast: fastEncoding))
        return Double(options.frameCount(duration: song.totalDuration)) * Double(w * h) / 1e6 / throughput(for: mode)
    }

    func refreshCacheSize() { cacheBytes = SegmentCache.sizeOnDisk }

    func clearCache() {
        SegmentCache.clear()
        refreshCacheSize()
    }

    private func exportUpdate(_ p: Double) {
        guard exportProgress != nil else { return }   // a late update after the export ended
        if exportVideoStart == nil && p > 0 { exportVideoStart = Date() }
        exportProgress = p
    }

    private func exportFinished(url: URL) {
        let seconds = Date().timeIntervalSince(exportStart ?? Date())
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        lastExportSummary = "Done in \(formatClock(seconds)) · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
        lastExport = url
        exportEnded()
    }

    private func exportEnded() {
        refreshCacheSize()
        exportProgress = nil
        exportStart = nil
        exportVideoStart = nil
    }

    func cancelExport() { exportTask?.cancel() }
}
