// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import AVFoundation
import AudioToolbox
import Foundation

/// What to play: which soundfont, which instrument per part, and which parts are audible.
struct AudioSettings {
    var soundFont: URL?            // nil = built-in macOS General MIDI bank
    var programs: [Int]            // per part
    var audible: [Bool]            // per part
    var volumes: [Float] = []      // per part, 1 = normal, up to 1.5; missing entries mean 1
    var custom: CustomAudio?       // the user's own recording, used instead of the synthesised instruments

    static func defaults(for song: Song) -> AudioSettings {
        AudioSettings(soundFont: nil, programs: song.parts.map(\.program),
                      audible: [Bool](repeating: true, count: song.parts.count))
    }
}

/// A recording the user supplies (for example exported from MuseScore from the same MIDI file).
/// It starts at the first beat of the song; `offset` nudges it earlier (negative) or later (positive), in seconds.
struct CustomAudio: Equatable {
    var url: URL
    var offset: Double = 0
}

/// Plays the song with one sampler per part, so each instrument gets its own sound and can be muted separately.
/// A second instance is used for offline export.
final class AudioPlayer {
    static let defaultBank = URL(fileURLWithPath:
        "/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls")

    private let engine: AVAudioEngine
    private let samplers: [AVAudioUnitSampler]
    private let sequencer: AVAudioSequencer
    private let song: Song
    private var programs: [Int]
    private var volumes: [Float]
    private(set) var soundFont: URL?

    init(song: Song, settings: AudioSettings) throws {
        let engine = AVAudioEngine()
        var samplers: [AVAudioUnitSampler] = []
        for _ in song.parts {
            let s = AVAudioUnitSampler()
            engine.attach(s)
            engine.connect(s, to: engine.mainMixerNode, format: nil)
            samplers.append(s)
        }
        let sequencer = AVAudioSequencer(audioEngine: engine)
        self.engine = engine
        self.samplers = samplers
        self.sequencer = sequencer
        self.song = song
        self.programs = settings.programs
        self.volumes = (0..<song.parts.count).map { $0 < settings.volumes.count ? settings.volumes[$0] : 1 }
        self.soundFont = settings.soundFont
        self.audible = settings.audible

        try sequencer.load(from: MIDIParser.playbackData(for: song), options: [])
        // Depending on the OS, `tracks` may or may not include the tempo track; the part tracks come last.
        let offset = max(0, sequencer.tracks.count - song.parts.count)
        for (i, sampler) in samplers.enumerated() where offset + i < sequencer.tracks.count {
            let track = sequencer.tracks[offset + i]
            track.destinationAudioUnit = sampler
            track.isMuted = !(i < settings.audible.count ? settings.audible[i] : true)
        }
        trackOffset = offset
        try loadAllInstruments()
        if let custom = settings.custom { try setCustomAudio(custom) }
        engine.prepare()
    }

    private var trackOffset = 0

    // The user's own recording, played through a player node. The (muted) sequencer still serves as the clock.
    private let customNode = AVAudioPlayerNode()
    private var customFile: AVAudioFile?
    private var customOffset = 0.0
    private var playing = false
    private var audible: [Bool] = []

    var hasCustomAudio: Bool { customFile != nil }

    func setCustomAudio(_ custom: CustomAudio?) throws {
        customNode.stop()
        if let custom {
            let file = try AVAudioFile(forReading: custom.url)
            if customNode.engine == nil { engine.attach(customNode) }
            engine.disconnectNodeOutput(customNode)
            engine.connect(customNode, to: engine.mainMixerNode, format: file.processingFormat)
            customFile = file
            customOffset = custom.offset
        } else {
            customFile = nil
        }
        applyMutes()
        if playing { startCustom() }
    }

    func setCustomOffset(_ offset: Double) {
        customOffset = offset
        if playing { startCustom() }
    }

    /// With a custom recording, every synthesised instrument is silent.
    private func applyMutes() {
        for i in samplers.indices {
            let idx = trackOffset + i
            guard idx < sequencer.tracks.count else { continue }
            sequencer.tracks[idx].isMuted = customFile != nil || !(i < audible.count ? audible[i] : true)
        }
    }

    /// (Re)starts the recording in step with the sequencer's current position.
    private func startCustom() {
        customNode.stop()
        guard let file = customFile else { return }
        let sr = file.processingFormat.sampleRate
        let fileTime = sequencer.currentPositionInSeconds - Song.leadIn - customOffset
        file.framePosition = 0
        if fileTime >= 0 {
            let start = AVAudioFramePosition(fileTime * sr)
            guard start < file.length else { return }
            customNode.scheduleSegment(file, startingFrame: start, frameCount: AVAudioFrameCount(file.length - start), at: nil)
            customNode.play()
        } else {
            let delay = -fileTime
            customNode.scheduleFile(file, at: nil)
            let when = AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: delay))
            customNode.play(at: when)
        }
    }

    // MARK: Instruments

    private func loadInstrument(_ i: Int) throws {
        let part = song.parts[i]
        let msb = part.isDrums ? kAUSampler_DefaultPercussionBankMSB : kAUSampler_DefaultMelodicBankMSB
        try samplers[i].loadSoundBankInstrument(
            at: soundFont ?? AudioPlayer.defaultBank,
            program: UInt8(part.isDrums ? 0 : min(max(programs[i], 0), 127)),
            bankMSB: UInt8(msb),
            bankLSB: UInt8(kAUSampler_DefaultBankLSB))
        applyVolume(i)   // reloading an instrument can reset the sampler's gain
    }

    /// 0...1 is the sampler's mixer volume; above 1 adds gain in dB so a quiet instrument can be boosted.
    private func applyVolume(_ i: Int) {
        let v = max(0, volumes[i])
        samplers[i].volume = min(v, 1)
        samplers[i].overallGain = v > 1 ? 20 * log10(v) : 0
    }

    func setVolume(_ part: Int, _ volume: Float) {
        volumes[part] = volume
        applyVolume(part)
    }

    private func loadAllInstruments() throws {
        for i in samplers.indices { try loadInstrument(i) }
    }

    func setProgram(_ part: Int, _ program: Int) throws {
        let old = programs[part]
        programs[part] = program
        do { try loadInstrument(part) } catch {
            programs[part] = old
            try? loadInstrument(part)
            throw error
        }
    }

    /// Switches every part to a different soundfont (nil = the built-in bank). Reverts if it can't be loaded.
    func setSoundFont(_ url: URL?) throws {
        let old = soundFont
        soundFont = url
        do { try loadAllInstruments() } catch {
            soundFont = old
            try? loadAllInstruments()
            throw error
        }
    }

    func setAudible(_ part: Int, _ on: Bool) {
        if part < audible.count { audible[part] = on }
        applyMutes()
        if !on { samplers[part].sendController(123, withValue: 0, onChannel: 0) } // cut sounding notes
    }

    // MARK: Transport

    /// Position on the video timeline in seconds.
    var position: Double {
        get { sequencer.currentPositionInSeconds }
        set {
            sequencer.currentPositionInSeconds = max(0, newValue)
            if playing { startCustom() }
        }
    }

    func play() throws {
        if !engine.isRunning { try engine.start() }
        sequencer.prepareToPlay()
        try sequencer.start()
        playing = true
        startCustom()
    }

    func pause() {
        playing = false
        customNode.stop()
        sequencer.stop()
        for s in samplers { s.sendController(123, withValue: 0, onChannel: 0) } // all notes off
    }

    /// Writes the audio for an export: the user's recording if there is one, otherwise the synthesised song.
    static func renderAudio(song: Song, settings: AudioSettings, to url: URL, duration: Double) throws {
        if let custom = settings.custom {
            try renderCustom(custom, to: url, duration: duration)
        } else {
            try AudioPlayer(song: song, settings: settings).renderOffline(to: url, duration: duration)
        }
    }

    /// Places the recording on the video timeline (silence for the lead-in, then the audio), cut to `duration`.
    static func renderCustom(_ custom: CustomAudio, to url: URL, duration: Double, sampleRate: Double = 44100) throws {
        let src = try AVAudioFile(forReading: custom.url)
        let outFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        guard let converter = AVAudioConverter(from: src.processingFormat, to: outFormat) else {
            throw NSError(domain: "FallingNotes", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "That audio file's format isn't supported."])
        }
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: outFormat.settings)
        let total = AVAudioFramePosition(duration * sampleRate)
        var written: AVAudioFramePosition = 0

        func writeSilence(_ frames: AVAudioFramePosition) throws {
            var left = max(0, min(frames, total - written))
            guard left > 0, let buf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192) else { return }
            for c in 0..<Int(outFormat.channelCount) { memset(buf.floatChannelData![c], 0, 8192 * 4) }
            while left > 0 {
                buf.frameLength = AVAudioFrameCount(min(left, 8192))
                try file.write(from: buf)
                left -= AVAudioFramePosition(buf.frameLength)
                written += AVAudioFramePosition(buf.frameLength)
            }
        }

        let lead = AVAudioFramePosition((Song.leadIn + custom.offset) * sampleRate)
        if lead >= 0 {
            try writeSilence(lead)
        } else {   // the recording starts before the video does: skip its first part
            src.framePosition = min(src.length, AVAudioFramePosition(Double(-lead) / sampleRate * src.processingFormat.sampleRate))
        }

        let inBuf = AVAudioPCMBuffer(pcmFormat: src.processingFormat, frameCapacity: 8192)!
        let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)!
        var finished = false
        while written < total && !finished {
            var readError: Error?
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, inStatus in
                // Reading past the end can throw instead of returning an empty buffer; both mean "no more audio".
                let remaining = src.length - src.framePosition
                if remaining <= 0 { inStatus.pointee = .endOfStream; return nil }
                do { try src.read(into: inBuf, frameCount: AVAudioFrameCount(min(8192, remaining))) } catch { readError = error }
                if readError != nil || inBuf.frameLength == 0 { inStatus.pointee = .endOfStream; return nil }
                inStatus.pointee = .haveData
                return inBuf
            }
            if let readError { throw readError }
            if status == .error, let e = convError { throw e }
            if status == .error { throw convError ?? NSError(domain: "FallingNotes", code: 3) }
            if outBuf.frameLength > 0 {
                outBuf.frameLength = AVAudioFrameCount(min(AVAudioFramePosition(outBuf.frameLength), total - written))
                try file.write(from: outBuf)
                written += AVAudioFramePosition(outBuf.frameLength)
            }
            if status == .endOfStream { finished = true }
        }
        try writeSilence(total - written)
    }

    /// Renders the whole timeline to a CAF file faster than real time.
    func renderOffline(to url: URL, duration: Double, sampleRate: Double = 44100) throws {
        engine.stop()
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        // Switching to offline mode re-initialises the samplers and drops their instruments, leaving only the
        // built-in test tone (every instrument became the same beep). Load them again now.
        try loadAllInstruments()
        try engine.start()
        sequencer.currentPositionInSeconds = 0
        sequencer.prepareToPlay()
        try sequencer.start()

        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat,
                                      frameCapacity: engine.manualRenderingMaximumFrameCount)!
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let total = AVAudioFramePosition(duration * sampleRate)
        while engine.manualRenderingSampleTime < total {
            let remaining = AVAudioFrameCount(total - engine.manualRenderingSampleTime)
            let status = try engine.renderOffline(min(remaining, buffer.frameCapacity), to: buffer)
            switch status {
            case .success: try file.write(from: buffer)
            case .error: throw NSError(domain: "FallingNotes", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "Audio rendering failed."])
            default: break
            }
        }
        sequencer.stop()
        engine.stop()
        engine.disableManualRenderingMode()
    }
}
