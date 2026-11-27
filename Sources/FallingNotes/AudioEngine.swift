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

    static func defaults(for song: Song) -> AudioSettings {
        AudioSettings(soundFont: nil, programs: song.parts.map(\.program),
                      audible: [Bool](repeating: true, count: song.parts.count))
    }
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
        engine.prepare()
    }

    private var trackOffset = 0

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
        let idx = trackOffset + part
        if idx < sequencer.tracks.count { sequencer.tracks[idx].isMuted = !on }
        if !on { samplers[part].sendController(123, withValue: 0, onChannel: 0) } // cut sounding notes
    }

    // MARK: Transport

    /// Position on the video timeline in seconds.
    var position: Double {
        get { sequencer.currentPositionInSeconds }
        set { sequencer.currentPositionInSeconds = max(0, newValue) }
    }

    func play() throws {
        if !engine.isRunning { try engine.start() }
        sequencer.prepareToPlay()
        try sequencer.start()
    }

    func pause() {
        sequencer.stop()
        for s in samplers { s.sendController(123, withValue: 0, onChannel: 0) } // all notes off
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
