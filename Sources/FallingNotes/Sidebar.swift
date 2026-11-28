// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import SwiftUI

// MARK: - Building blocks

/// A rounded panel with a small icon + title, used for each section of the sidebar.
struct Card<Accessory: View, Content: View>: View {
    let title: String
    let icon: String
    let accessory: Accessory
    let content: Content

    init(_ title: String, icon: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

extension Card where Accessory == EmptyView {
    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.init(title, icon: icon, accessory: { EmptyView() }, content: content)
    }
}

/// A label on the left, a control on the right.
struct SettingRow<Control: View>: View {
    let label: String
    let control: Control
    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12.5))
            Spacer(minLength: 8)
            control
        }
    }
}

/// The small rounded tile behind the eye / speaker buttons.
struct IconBadge: View {
    let systemImage: String
    var tint: Color? = nil          // nil = neutral
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(tint ?? Color.primary.opacity(0.7))
            .frame(width: 28, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill((tint ?? Color.primary).opacity(tint == nil ? 0.07 : 0.17)))
    }
}

/// Checkbox-style selection dot.
struct SelectDot: View {
    let selected: Bool
    var partial = false
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : partial ? "minus.circle.fill" : "circle")
            .font(.system(size: 16))
            .foregroundStyle(selected || partial ? Color.accentColor : Color.primary.opacity(0.3))
    }
}

/// Menu for how notes appear in the video. `look` is nil when the instruments it controls differ.
struct LookMenu: View {
    let look: PartLook?
    let onPick: (PartLook) -> Void

    var body: some View {
        Menu {
            ForEach(PartLook.allCases) { option in
                Button { onPick(option) } label: {
                    Label(option.label, systemImage: look == option ? "checkmark" : option.icon)
                }
            }
        } label: {
            IconBadge(systemImage: look?.icon ?? "circle.dashed", tint: tint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Notes in the video: \(look?.label ?? "mixed")")
    }

    private var tint: Color? {
        switch look {
        case .faint: return .orange
        case .hidden: return .gray
        case .shown: return nil
        case nil: return .purple
        }
    }
}

/// Speaker button. `audible` is nil when the instruments it controls differ.
struct MuteButton: View {
    let audible: Bool?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            switch audible {
            case .some(true): IconBadge(systemImage: "speaker.wave.2.fill", tint: .accentColor)
            case .some(false): IconBadge(systemImage: "speaker.slash.fill", tint: .red)
            case .none: IconBadge(systemImage: "speaker.wave.1", tint: .purple)
            }
        }
        .buttonStyle(.plain)
        .help(audible == true ? "Mute in the audio" : "Unmute in the audio")
    }
}

/// Slider plus a box to type an exact percentage (0-150).
struct VolumeControl: View {
    let value: Double
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "speaker.fill").font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: Binding(get: { value }, set: onChange), in: 0...1.5)
                .controlSize(.small)
            TextField("", value: Binding(
                get: { Int((value * 100).rounded()) },
                set: { onChange(Double(min(max($0, 0), 150)) / 100) }),
                      format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .controlSize(.small)
                .monospacedDigit()
                .frame(width: 46)
            Text("%").font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar

struct SettingsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                SongCard()
                InstrumentsCard()
                SoundCard()
                LookCard()
                ExportCard()
                CreditFooter()
            }
            .padding(14)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

/// A small credit at the bottom of the sidebar.
struct CreditFooter: View {
    private var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev" }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text("Made by Diego Zamarron")
                    .foregroundStyle(.secondary)
                Text("·").foregroundStyle(.tertiary)
                Link("zamarron.com", destination: URL(string: "https://zamarron.com")!)
            }
            .font(.system(size: 11, weight: .medium))
            HStack(spacing: 4) {
                Text("Version \(version)")
                Text("·")
                Link("Source & license", destination: URL(string: "https://github.com/diegozamarron/FallingNotes")!)
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }
}

struct SongCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.30, green: 0.60, blue: 0.98),
                                                  Color(red: 0.47, green: 0.84, blue: 0.27)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "pianokeys").font(.system(size: 19, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { model.openPanel() } label: {
                if model.song == nil { Label("Open…", systemImage: "folder") } else { Image(systemName: "folder") }
            }
            .controlSize(.small)
            .help("Open a different MIDI file (⌘O)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var title: String {
        model.song?.url.deletingPathExtension().lastPathComponent ?? "No song loaded"
    }

    private var subtitle: String {
        guard let song = model.song else { return "Open or drop a MIDI file" }
        return "\(song.notes.count.formatted()) notes · \(formatClock(song.duration)) · \(song.parts.count) instruments"
    }
}

// MARK: - Instruments

struct InstrumentsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.song != nil {
            Card("Instruments", icon: "music.note.list", accessory: {
                HStack(spacing: 6) {
                    Button("Select all") { model.selectAll() }
                    Button { model.autoGroup() } label: { Label("Auto-group", systemImage: "wand.and.stars") }
                        .help("Group instruments by family: strings, keys, brass…")
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }) {
                VStack(spacing: 10) {
                    if !model.selection.isEmpty { SelectionBar() }
                    ForEach(model.groups) { group in GroupSection(group: group) }
                    ForEach(model.ungroupedParts, id: \.self) { i in PartRow(index: i) }
                    Text("Tick the circles to select several instruments, then change them together or group them. Eye: show, fade into the background, or hide the notes. Speaker: mute the sound.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Appears while instruments are selected: one set of controls that changes all of them.
struct SelectionBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let idx = model.selectedIndices
        let colors = idx.compactMap { model.parts.indices.contains($0) ? model.parts[$0].color : nil }
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("\(idx.count) selected").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button { model.createGroup(from: idx) } label: { Label("Group", systemImage: "rectangle.3.group") }
                    .help("Put the selected instruments in a group")
                if idx.contains(where: { model.groupIndex(containing: $0) != nil }) {
                    Button("Ungroup") { model.removeFromGroups(idx) }
                }
                Button { model.clearSelection() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear the selection")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            HStack(spacing: 8) {
                Text("Change all:").font(.system(size: 11.5)).foregroundStyle(.secondary)
                ColorChoiceButton(
                    selection: Binding(get: { model.commonColor(idx) ?? colors.first ?? .gray },
                                       set: { model.setColor(idx, $0) }),
                    presets: Palette.named, diameter: 22,
                    mixed: model.commonColor(idx) == nil ? colors : [])
                LookMenu(look: model.commonLook(idx)) { model.setLook(idx, $0) }
                MuteButton(audible: model.commonAudible(idx)) {
                    model.setAudible(idx, !(model.commonAudible(idx) ?? false))
                }
                Spacer(minLength: 0)
            }
            InstrumentButton(program: model.commonProgram(idx)) { model.setProgram(idx, $0) }
            VolumeControl(value: model.averageVolume(idx)) { model.scaleVolumes(idx, toAverage: $0) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35)))
    }
}

/// A named group: its own controls change every member; members can still be adjusted one by one.
struct GroupSection: View {
    @EnvironmentObject var model: AppModel
    let group: PartGroup

    var body: some View {
        let members = group.members.filter { model.parts.indices.contains($0) }
        let memberSet = Set(members)
        let allSelected = memberSet.isSubset(of: model.selection)
        let someSelected = !memberSet.isDisjoint(with: model.selection)
        let colors = members.map { model.parts[$0].color }

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { model.toggleSelection(of: group) } label: {
                    SelectDot(selected: allSelected, partial: someSelected && !allSelected)
                }
                .buttonStyle(.plain)
                .help("Select every instrument in this group")

                Button { withAnimation(.easeInOut(duration: 0.15)) { model.toggleCollapsed(group.id) } } label: {
                    Image(systemName: group.collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 12)
                }
                .buttonStyle(.plain)

                TextField("Group name", text: Binding(get: { group.name }, set: { model.renameGroup(group.id, to: $0) }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))

                Text("\(members.count)")
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))

                ColorChoiceButton(
                    selection: Binding(get: { model.commonColor(members) ?? colors.first ?? .gray },
                                       set: { model.setColor(members, $0) }),
                    presets: Palette.named, diameter: 22,
                    mixed: model.commonColor(members) == nil ? colors : [])
                LookMenu(look: model.commonLook(members)) { model.setLook(members, $0) }
                MuteButton(audible: model.commonAudible(members)) {
                    model.setAudible(members, !(model.commonAudible(members) ?? false))
                }
                Menu {
                    Button("Select members") { model.selection.formUnion(memberSet) }
                    Button("Ungroup", role: .destructive) { model.ungroup(group.id) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 26)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            if !group.collapsed {
                VolumeControl(value: model.averageVolume(members)) { model.scaleVolumes(members, toAverage: $0) }
                    .help("Moves the whole group up or down, keeping the balance between its instruments")
                VStack(spacing: 6) {
                    ForEach(members, id: \.self) { PartRow(index: $0) }
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Capsule().fill(Color.accentColor.opacity(0.35)).frame(width: 2)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor.opacity(0.2)))
    }
}

struct PartRow: View {
    @EnvironmentObject var model: AppModel
    let index: Int
    @State private var expanded = false

    var body: some View {
        if let song = model.song, model.parts.indices.contains(index), song.parts.indices.contains(index) {
            let part = song.parts[index]
            let state = model.parts[index]
            let selected = model.isSelected(index)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { model.toggleSelected(index) } label: { SelectDot(selected: selected) }
                        .buttonStyle(.plain)
                        .help("Select")

                    ColorChoiceButton(selection: $model.parts[index].color, presets: Palette.named, diameter: 22)
                        .disabled(part.isDrums)

                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.displayName(index))
                                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text(subtitle(part))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(expanded ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show instrument and volume")

                    LookMenu(look: state.look) { model.setLook(index, $0) }
                    MuteButton(audible: state.audible) { model.setAudible(index, !state.audible) }
                }

                if expanded {
                    TextField("Title in the key", text: Binding(get: { model.parts[index].title },
                                                                set: { model.setTitle(index, $0) }),
                              prompt: Text(part.isDrums ? "Drums" : GM.names[state.program]))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    if !part.isDrums {
                        InstrumentButton(program: state.program) { model.setProgram(index, $0) }
                    }
                    VolumeControl(value: state.volume) { model.setVolume(index, $0) }
                        .opacity(state.audible ? 1 : 0.45)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor.opacity(0.5) : Color.clear))
        }
    }

    /// Kept short so it fits next to the buttons: the track's name, then how many notes it plays.
    private func subtitle(_ part: Part) -> String {
        [part.trackName, "\(part.noteCount) notes"].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Sound, look, export

struct SoundCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Sound", icon: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "music.quarternote.3").foregroundStyle(.secondary)
                    Text(model.soundFont?.lastPathComponent ?? "Built-in macOS sounds")
                        .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Soundfont…") { model.chooseSoundFont() }
                    if model.soundFont != nil { Button("Reset") { model.setSoundFont(nil) } }
                }
                .controlSize(.small)
                if model.song != nil { OwnAudioSection() }
                if model.song != nil && model.customAudio == nil {
                    Button { model.resetInstruments() } label: {
                        Label("Reset instruments to the MIDI file's", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Use a recording (say, exported from MuseScore from the same MIDI file) instead of the built-in sounds.
struct OwnAudioSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            HStack(spacing: 8) {
                Image(systemName: "waveform.badge.plus").foregroundStyle(.secondary)
                Text(model.customAudio?.url.lastPathComponent ?? "Your own audio")
                    .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Button(model.customAudio == nil ? "Choose…" : "Change…") { model.chooseAudio() }
                if model.customAudio != nil { Button("Remove") { model.setCustomAudio(nil) } }
            }
            .controlSize(.small)
            if let custom = model.customAudio {
                SettingRow("Nudge") {
                    TextField("", value: Binding(get: { custom.offset }, set: { model.setAudioOffset($0) }),
                              format: .number.precision(.fractionLength(0...2)))
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                        .frame(width: 60).controlSize(.small)
                    Text("seconds").font(.system(size: 11)).foregroundStyle(.secondary)
                    Stepper("", value: Binding(get: { custom.offset }, set: { model.setAudioOffset($0) }), in: -10...10, step: 0.05)
                        .labelsHidden().controlSize(.small)
                }
                Text("Plays instead of the instrument sounds, starting with the first beat of the MIDI file, so audio exported from the same score lines up. Use Nudge if it's slightly early or late. Instrument sound settings are off while this is used.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Optional: use a recording of this song, such as audio exported from MuseScore from the same MIDI file.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One of the three video styles, as a tile with an icon.
struct VisualModeButton: View {
    let mode: VisualMode
    @Binding var selection: VisualMode

    private var icon: String {
        switch mode {
        case .simple: return "square.grid.2x2"
        case .polished: return "sparkle"
        case .cinematic: return "wand.and.stars"
        }
    }

    var body: some View {
        let selected = selection == mode
        Button { selection = mode } label: {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(mode.label).font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.75))
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Color.accentColor : Color.primary.opacity(0.07)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct LookCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Look", icon: "paintbrush") {
            VStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Video style").font(.system(size: 12.5))
                    HStack(spacing: 6) {
                        ForEach(VisualMode.allCases) { VisualModeButton(mode: $0, selection: $model.visualMode) }
                    }
                    Text(model.visualMode.detail)
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.visualMode != .simple {
                    SettingRow("Key fade") {
                        Slider(value: $model.keyFade, in: 0...1.5).frame(width: 130).controlSize(.small)
                        Text(model.keyFade < 0.05 ? "off" : String(format: "%.1fs", model.keyFade))
                            .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                    }
                }
                SettingRow("Fall time") {
                    Slider(value: $model.fallSeconds, in: 1...3).frame(width: 130).controlSize(.small)
                    Text(String(format: "%.1fs", model.fallSeconds))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                }
                SettingRow("Faint opacity") {
                    Slider(value: $model.faintOpacity, in: 0.1...0.7).frame(width: 130).controlSize(.small)
                    Text("\(Int((model.faintOpacity * 100).rounded()))%")
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 32, alignment: .trailing)
                }
                SettingRow("Full 88-key keyboard") {
                    Toggle("", isOn: $model.fullKeyboard).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingRow("Glow on active notes") {
                    Toggle("", isOn: $model.glow).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                SettingRow("Show a key") {
                    Toggle("", isOn: $model.showKey).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if model.showKey {
                    SettingRow("Key position") {
                        Picker("", selection: $model.keyCorner) {
                            ForEach(LegendCorner.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().pickerStyle(.segmented).frame(width: 140).controlSize(.small)
                    }
                    Text("Lists each visible instrument with its colour. Rename instruments by opening them in the list.")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SettingRow("Background") {
                    ColorChoiceButton(selection: $model.background, presets: Palette.backgrounds, diameter: 22)
                }
            }
        }
    }
}

struct ExportCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card("Export", icon: "square.and.arrow.up") {
            VStack(spacing: 10) {
                SettingRow("Size") {
                    Picker("", selection: $model.resolution) {
                        ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Frame rate") {
                    Picker("", selection: $model.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                }
                SettingRow("Codec") {
                    Picker("", selection: $model.codec) {
                        ForEach(VideoCodec.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingRow("Include audio") {
                    Toggle("", isOn: $model.includeAudio).labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                if model.codec == .h264 {
                    SettingRow("Encoding") {
                        Picker("", selection: $model.encodingMode) {
                            ForEach(EncodingMode.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    .help("Fastest uses the hardware encoder and the CPU together. Single stream uses only the CPU encoder, so the file has one consistent stream (best compatibility). Efficient uses only the hardware encoder: slower, but cooler and quieter.")
                }

                if let song = model.song, model.exportProgress == nil {
                    let o = model.exportOptions
                    let bytes = ByteCountFormatter.string(fromByteCount: Int64(o.estimatedBytes(duration: song.totalDuration)),
                                                          countStyle: .file)
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text("\(formatClock(song.totalDuration)) · \(o.frameCount(duration: song.totalDuration).formatted()) frames · up to \(bytes)"
                             + (model.estimatedRenderSeconds().map { " · renders in about \(formatClock($0))" } ?? ""))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11))
                }

                if let p = model.exportProgress, let start = model.exportStart {
                    ExportProgressView(progress: p, start: start, videoStart: model.exportVideoStart,
                                       totalFrames: model.song.map { model.exportOptions.frameCount(duration: $0.totalDuration) } ?? 0)
                    Button("Cancel") { model.cancelExport() }.controlSize(.small)
                } else {
                    Button { model.startExport() } label: {
                        Label("Export Video…", systemImage: "film").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.song == nil)
                }
                if model.cacheBytes > 1_000_000 {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        Text("Saved video pieces: \(ByteCountFormatter.string(fromByteCount: model.cacheBytes, countStyle: .file)) (re-exports reuse what hasn't changed)")
                            .foregroundStyle(.secondary).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Clear") { model.clearCache() }.controlSize(.mini)
                    }
                    .font(.system(size: 11))
                }
                if let summary = model.lastExportSummary {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(summary).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let url = model.lastExport {
                            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                .controlSize(.mini)
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        }
    }
}
