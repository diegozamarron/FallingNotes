import SwiftUI
import Foundation

struct FallingNotesApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Also put the app's colours into the system colour panel's "Color Palettes" tab, for "Custom…" pickers.
        let list = NSColorList(name: "Falling Notes")
        for (name, color) in Palette.named + Palette.backgrounds {
            if let c = NSColor(cgColor: color) { list.setColor(c, forKey: name) }
        }
        NSColorPanel.shared.attachColorList(list)
    }

    var body: some Scene {
        // A single-instance Window, not a WindowGroup: this app has one shared model and one preview, so extra
        // windows (new-window commands, restored windows, one per opened file) would each run a full copy of the
        // UI and its render loop.
        Window("Falling Notes", id: "main") {
            ContentView()
                .environmentObject(model)
                .onOpenURL { model.load(url: $0) }
                .onAppear {
                    // Testing hook: `open -a FallingNotes.app file.mid --args --autoplay`
                    if CommandLine.arguments.contains("--autoplay") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.play() }
                    }
                    // Testing hook: runs a real GUI-path export and reports the longest main-thread stall
                    // (how long the window would have frozen): `--autoexport /path/out.mp4`
                    let args = CommandLine.arguments
                    if let i = args.firstIndex(of: "--autoexport"), args.count > i + 1 {
                        let out = URL(fileURLWithPath: args[i + 1])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            var last = CFAbsoluteTimeGetCurrent(), worst = 0.0
                            let started = last
                            model.startExport(to: out)
                            Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { timer in
                                let now = CFAbsoluteTimeGetCurrent()
                                worst = max(worst, now - last - 0.01)
                                last = now
                                if model.exportProgress == nil {
                                    timer.invalidate()
                                    let o = model.exportOptions
                                    let est = ByteCountFormatter.string(
                                        fromByteCount: Int64(o.estimatedBytes(duration: model.total)), countStyle: .file)
                                    print(String(format: "export took %.1fs; longest main-thread stall %.0f ms; %@ (estimate was %@)",
                                                 now - started, worst * 1000, model.lastExportSummary ?? "no summary", est))
                                    fflush(stdout)
                                    exit(0)
                                }
                            }
                        }
                    }
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open MIDI File…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
        }
    }
}

// Testing hook: renders the real window offscreen to a PNG.
//   FallingNotes --snapshot in.mid out.png [--autogroup] [--select 0,1] [--collapse] [--expand]
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 2 {
    let args = CommandLine.arguments
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = AppModel()
        model.load(url: URL(fileURLWithPath: args[i + 1]))
        if args.contains("--autogroup") { model.autoGroup() }
        if let s = args.firstIndex(of: "--select"), args.count > s + 1 {
            model.selection = Set(args[s + 1].split(separator: ",").compactMap { Int($0) })
        }
        let host = NSHostingView(rootView: ContentView().environmentObject(model))
        model.seek(to: 30)    // show some notes instead of the empty lead-in
        let size = NSSize(width: 1200, height: args.contains("--tall") ? 1900 : 800)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 2]))
            print("wrote \(args[i + 2])")
        }
        exit(0)
    }
}

// Testing hook: checks the group/selection operations. FallingNotes --selftest in.mid
if let i = CommandLine.arguments.firstIndex(of: "--selftest"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated {
        let m = AppModel()
        m.load(url: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
        @MainActor func vols(_ ix: [Int]) -> String { ix.map { String(format: "%.2f", m.parts[$0].volume) }.joined(separator: " ") }
        m.setVolume(0, 1.0); m.setVolume(1, 0.5); m.setVolume(2, 0.8)
        print("before            volumes: \(vols([0, 1, 2]))  avg \(String(format: "%.2f", m.averageVolume([0, 1, 2])))")
        m.scaleVolumes([0, 1, 2], toAverage: 0.4)
        print("group -> avg 0.40 volumes: \(vols([0, 1, 2]))  avg \(String(format: "%.2f", m.averageVolume([0, 1, 2])))  (ratios kept)")
        m.scaleVolumes([0, 1, 2], toAverage: 1.5)
        print("group -> avg 1.50 volumes: \(vols([0, 1, 2]))  (each member capped at 1.50)")
        m.autoGroup()
        print("auto-group: " + m.groups.map { "\($0.name)=\($0.members)" }.joined(separator: ", "))
        let gid = m.createGroup(from: [0, 5], name: "Mix")
        print("after moving parts 0,5 into 'Mix': " + m.groups.map { "\($0.name)=\($0.members)" }.joined(separator: ", "))
        m.setLook([0, 5], .faint); m.setAudible([0, 5], false)
        print("bulk look/audible -> parts 0,5: \(m.parts[0].look)/\(m.parts[0].audible), \(m.parts[5].look)/\(m.parts[5].audible); part 1: \(m.parts[1].look)/\(m.parts[1].audible)")
        print("common look of [0,1] = \(String(describing: m.commonLook([0, 1]))) (nil = differ)")
        m.setProgram([0, 1], 41)
        print("bulk instrument -> \(m.parts[0].program), \(m.parts[1].program) (41 = Viola)")
        m.ungroup(gid!)
        print("after ungroup: " + m.groups.map { "\($0.name)=\($0.members)" }.joined(separator: ", "))
        exit(0)
    }
}

// Benchmark: FallingNotes --bench in.mid   (times parsing, audio setup and per-frame drawing)
if let i = CommandLine.arguments.firstIndex(of: "--bench"), CommandLine.arguments.count > i + 1 {
    func ms(_ block: () throws -> Void) rethrows -> Double {
        let t = CFAbsoluteTimeGetCurrent(); try block(); return (CFAbsoluteTimeGetCurrent() - t) * 1000
    }
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    var song: Song!
    print(String(format: "parse            %7.0f ms", try ms { song = try MIDIParser.load(url: url) }))
    print("                 \(song.notes.count) notes, \(song.parts.count) parts")
    var player: AudioPlayer?
    print(String(format: "audio setup      %7.0f ms", try ms {
        player = try AudioPlayer(song: song, settings: .defaults(for: song)) }))
    _ = player
    var w = 1280, h = 720
    if let r = CommandLine.arguments.firstIndex(of: "--size"), CommandLine.arguments.count > r + 1 {
        let wh = CommandLine.arguments[r + 1].split(separator: "x").compactMap { Int($0) }
        if wh.count == 2 { (w, h) = (wh[0], wh[1]) }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
    let frames = 120
    let draw = ms {
        for f in 0..<frames {
            drawFrame(ctx, size: CGSize(width: w, height: h),
                      videoTime: Song.leadIn + Double(f) * song.duration / Double(frames), song: song, style: Style())
        }
    }
    print(String(format: "drawFrame (%dx%d) %7.2f ms/frame  = %.0f frames/s on one core", w, h, draw / Double(frames), 1000 * Double(frames) / draw))
    exit(0)
}

// Headless mode for testing: FallingNotes --export in.mid out.mp4 [--fps 30] [--res 720|1080|2160|vertical] [--hevc] [--silent]
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--export"), args.count > i + 2 {
    let input = URL(fileURLWithPath: args[i + 1])
    let output = URL(fileURLWithPath: args[i + 2])
    var options = ExportOptions()
    if let f = args.firstIndex(of: "--fps"), args.count > f + 1, let v = Int(args[f + 1]) { options.fps = v }
    if let r = args.firstIndex(of: "--res"), args.count > r + 1 {
        switch args[r + 1] {
        case "720": options.resolution = .p720
        case "2160": options.resolution = .p2160
        case "vertical": options.resolution = .vertical
        default: options.resolution = .p1080
        }
    }
    if args.contains("--hevc") { options.codec = .hevc }
    if args.contains("--silent") { options.includeAudio = false }
    if let b = args.firstIndex(of: "--bitrate-scale"), args.count > b + 1, let v = Double(args[b + 1]) { options.bitrateScale = v }
    func list(_ flag: String) -> [Int] {
        guard let i = args.firstIndex(of: flag), args.count > i + 1 else { return [] }
        return args[i + 1].split(separator: ",").compactMap { Int($0) }
    }
    Task {
        do {
            let song = try MIDIParser.load(url: input)
            print("Loaded \(song.notes.count) notes, \(String(format: "%.1f", song.duration))s")
            for (i, p) in song.parts.enumerated() {
                print("  part \(i): \(p.name) (track \(p.track), ch \(p.channel + 1), \(p.noteCount) notes)")
            }
            var style = Style()
            style.hidden = Set(list("--hide"))
            style.faint = Set(list("--faint"))
            var audio = AudioSettings.defaults(for: song)
            for i in list("--mute") where i < audio.audible.count { audio.audible[i] = false }
            // --volume 0=0.5,2=1.2  (part index = gain, 1 is normal)
            audio.volumes = [Float](repeating: 1, count: song.parts.count)
            if let v = args.firstIndex(of: "--volume"), args.count > v + 1 {
                for pair in args[v + 1].split(separator: ",") {
                    let kv = pair.split(separator: "=")
                    if kv.count == 2, let i = Int(kv[0]), let g = Float(kv[1]), i < audio.volumes.count { audio.volumes[i] = g }
                }
            }
            if let s = args.firstIndex(of: "--soundfont"), args.count > s + 1 {
                audio.soundFont = URL(fileURLWithPath: args[s + 1])
            }
            let tick: @Sendable (Double) -> Void = { p in
                print(String(format: "\rprogress %.0f%%", p * 100), terminator: "")
                fflush(stdout)
            }
            if args.contains("--hybrid") {
                // --hybrid [--hw N] [--sw M] [--segment SECONDS]: segments encoded by hardware and software at once
                var config = HybridConfig()
                config.verbose = true
                if let i = args.firstIndex(of: "--hw"), args.count > i + 1, let n = Int(args[i + 1]) { config.hardwareLanes = n }
                if let i = args.firstIndex(of: "--sw"), args.count > i + 1, let n = Int(args[i + 1]) { config.softwareLanes = n }
                if let i = args.firstIndex(of: "--x264"), args.count > i + 1, let n = Int(args[i + 1]) { config.x264Lanes = n }
                if let i = args.firstIndex(of: "--mode"), args.count > i + 1, let m = EncodingMode(rawValue: args[i + 1]) {
                    let verbose = config.verbose
                    config = SegmentedExporter.plan(codec: options.codec, mode: m)   // --mode fastest|compatible|efficient
                    config.verbose = verbose
                }
                if args.contains("--no-cache") { config.useCache = false }
                if let i = args.firstIndex(of: "--segment"), args.count > i + 1, let n = Double(args[i + 1]) { config.segmentSeconds = n }
                try await SegmentedExporter.export(song: song, style: style, audio: audio, options: options,
                                                   config: config, to: output, progress: tick)
            } else {
                try await Exporter.export(song: song, style: style, audio: audio, options: options, to: output, progress: tick)
            }
            print("\nWrote \(output.path)")
            exit(0)
        } catch {
            print("\nError: \(error.localizedDescription)")
            exit(1)
        }
    }
    dispatchMain()
} else {
    FallingNotesApp.main()
}
