// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                PreviewPane(transport: model.transport)
                TransportBar(transport: model.transport)
            }
            .padding(16)
            .background(Color(nsColor: .windowBackgroundColor))
            Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 1)
            SettingsView()
                .frame(width: 372)
        }
        .frame(minWidth: 1060, minHeight: 660)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            model.load(url: url)
            return true
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

}

struct PreviewPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var transport: Transport

    var body: some View {
        let size = model.resolution.size
        let style = model.style      // built once per update, not once per drawn frame
        return ZStack {
            if let song = model.song {
                // Redraws on a display link while playing; scrubbing or changing settings while paused re-runs this.
                FramePreview(model: model, song: song, style: style, playing: transport.isPlaying)
            } else {
                VStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.60, blue: 0.98),
                                                          Color(red: 0.47, green: 0.84, blue: 0.27)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "pianokeys").font(.system(size: 34, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 76, height: 76)
                    Text("Drop a MIDI file here").font(.title3.weight(.semibold)).foregroundStyle(.white.opacity(0.9))
                    Button("Open MIDI…") { model.openPanel() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
        .aspectRatio(CGFloat(size.width) / CGFloat(size.height), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }

}

struct TransportBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var transport: Transport

    var body: some View {
        HStack(spacing: 12) {
            Button { model.togglePlay() } label: {
                Image(systemName: transport.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(model.song == nil ? Color.gray.opacity(0.5) : Color.accentColor))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(model.song == nil)

            Slider(value: Binding(get: { transport.scrubTime }, set: { model.seek(to: $0) }),
                   in: 0...max(model.total, 0.01))
                .disabled(model.song == nil)
            Text(timeLabel).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var timeLabel: String {
        func f(_ s: Double) -> String { String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        return "\(f(max(0, transport.scrubTime - Song.leadIn))) / \(f(model.song?.duration ?? 0))"
    }
}

/// Progress bar with elapsed time, an estimate of the time left, and the frame count.
struct ExportProgressView: View {
    let progress: Double
    let start: Date
    let videoStart: Date?       // when frame rendering began (after the audio was prepared)
    let totalFrames: Int

    var body: some View {
        // Re-evaluates every second so the clock keeps moving between progress updates.
        TimelineView(.periodic(from: start, by: 1)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: progress) { Text("Rendering… \(Int(progress * 100))%") }
                Text(detail(now: now))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func detail(now: Date) -> String {
        var parts = ["Elapsed \(formatClock(now.timeIntervalSince(start)))"]
        if let videoStart, progress > 0.02 {
            // Time spent on video so far, scaled by how much is left. Excludes the one-off audio preparation.
            let spent = now.timeIntervalSince(videoStart)
            parts.append("about \(formatClock(spent * (1 - progress) / progress)) left")
        } else {
            parts.append(videoStart == nil ? "preparing audio…" : "estimating time left…")
        }
        if totalFrames > 0 {
            parts.append("frame \(Int(Double(totalFrames) * progress).formatted()) of \(totalFrames.formatted())")
        }
        return parts.joined(separator: " · ")
    }
}

/// A colour swatch that opens the app's own palette (named colours) with a "Custom…" option for anything else.
struct ColorChoiceButton: View {
    @Binding var selection: Color
    let presets: [(name: String, color: CGColor)]
    var diameter: CGFloat = 20
    /// When several instruments with different colours share this swatch, they're shown as a colour wheel.
    var mixed: [Color] = []
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            Group {
                if mixed.count > 1 {
                    Circle().fill(AngularGradient(colors: mixed + [mixed[0]], center: .center))
                } else {
                    Circle().fill(selection)
                }
            }
            .frame(width: diameter, height: diameter)
            .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Choose a colour")
        .popover(isPresented: $open, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 10) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 4), spacing: 8) {
                    ForEach(presets.indices, id: \.self) { i in
                        let preset = Color(cgColor: presets[i].color)
                        Button {
                            selection = preset
                            open = false
                        } label: {
                            Circle().fill(preset)
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                                .overlay {
                                    if matches(presets[i].color) {
                                        Image(systemName: "checkmark").font(.caption.bold())
                                            .foregroundStyle(.black.opacity(0.7))
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help(presets[i].name)
                    }
                }
                Divider()
                ColorPicker("Custom…", selection: $selection)
            }
            .padding(12)
        }
    }

    private func matches(_ cg: CGColor) -> Bool {
        guard mixed.count <= 1 else { return false }
        guard let a = NSColor(selection).usingColorSpace(.sRGB), let b = NSColor(cgColor: cg)?.usingColorSpace(.sRGB)
        else { return false }
        return abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01
            && abs(a.blueComponent - b.blueComponent) < 0.01
    }
}

/// Shows the current instrument; the 128-item list is only built when the popover is opened.
struct InstrumentButton: View {
    let program: Int?           // nil = the selected instruments differ ("Mixed")
    let onPick: (Int) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            HStack {
                Text(program.map { "\($0 + 1). \(GM.names[$0])" } ?? "Mixed instruments").lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .popover(isPresented: $open, arrowEdge: .leading) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<128, id: \.self) { i in
                            Button {
                                onPick(i)
                                open = false
                            } label: {
                                HStack {
                                    Text("\(i + 1). \(GM.names[i])")
                                    Spacer()
                                    if i == program { Image(systemName: "checkmark") }   // nothing when mixed
                                }
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(i == program ? Color.accentColor.opacity(0.15) : .clear)
                            .id(i)
                        }
                    }
                }
                .onAppear { if let program { proxy.scrollTo(program, anchor: .center) } }
            }
            .frame(width: 270, height: 340)
        }
    }
}
