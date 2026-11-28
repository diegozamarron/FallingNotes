// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import AudioToolbox
import Foundation

enum GM {
    static let names: [String] = [
        "Acoustic Grand Piano", "Bright Acoustic Piano", "Electric Grand Piano", "Honky-tonk Piano",
        "Electric Piano 1", "Electric Piano 2", "Harpsichord", "Clavinet",
        "Celesta", "Glockenspiel", "Music Box", "Vibraphone",
        "Marimba", "Xylophone", "Tubular Bells", "Dulcimer",
        "Drawbar Organ", "Percussive Organ", "Rock Organ", "Church Organ",
        "Reed Organ", "Accordion", "Harmonica", "Tango Accordion",
        "Acoustic Guitar (nylon)", "Acoustic Guitar (steel)", "Electric Guitar (jazz)", "Electric Guitar (clean)",
        "Electric Guitar (muted)", "Overdriven Guitar", "Distortion Guitar", "Guitar Harmonics",
        "Acoustic Bass", "Electric Bass (finger)", "Electric Bass (pick)", "Fretless Bass",
        "Slap Bass 1", "Slap Bass 2", "Synth Bass 1", "Synth Bass 2",
        "Violin", "Viola", "Cello", "Contrabass",
        "Tremolo Strings", "Pizzicato Strings", "Orchestral Harp", "Timpani",
        "String Ensemble 1", "String Ensemble 2", "Synth Strings 1", "Synth Strings 2",
        "Choir Aahs", "Voice Oohs", "Synth Voice", "Orchestra Hit",
        "Trumpet", "Trombone", "Tuba", "Muted Trumpet",
        "French Horn", "Brass Section", "Synth Brass 1", "Synth Brass 2",
        "Soprano Sax", "Alto Sax", "Tenor Sax", "Baritone Sax",
        "Oboe", "English Horn", "Bassoon", "Clarinet",
        "Piccolo", "Flute", "Recorder", "Pan Flute",
        "Blown Bottle", "Shakuhachi", "Whistle", "Ocarina",
        "Lead 1 (square)", "Lead 2 (sawtooth)", "Lead 3 (calliope)", "Lead 4 (chiff)",
        "Lead 5 (charang)", "Lead 6 (voice)", "Lead 7 (fifths)", "Lead 8 (bass + lead)",
        "Pad 1 (new age)", "Pad 2 (warm)", "Pad 3 (polysynth)", "Pad 4 (choir)",
        "Pad 5 (bowed)", "Pad 6 (metallic)", "Pad 7 (halo)", "Pad 8 (sweep)",
        "FX 1 (rain)", "FX 2 (soundtrack)", "FX 3 (crystal)", "FX 4 (atmosphere)",
        "FX 5 (brightness)", "FX 6 (goblins)", "FX 7 (echoes)", "FX 8 (sci-fi)",
        "Sitar", "Banjo", "Shamisen", "Koto",
        "Kalimba", "Bag pipe", "Fiddle", "Shanai",
        "Tinkle Bell", "Agogo", "Steel Drums", "Woodblock",
        "Taiko Drum", "Melodic Tom", "Synth Drum", "Reverse Cymbal",
        "Guitar Fret Noise", "Breath Noise", "Seashore", "Bird Tweet",
        "Telephone Ring", "Helicopter", "Applause", "Gunshot",
    ]
}

/// One instrument line in the song: a (track, channel, program) combination.
struct Part {
    var track: Int
    var channel: Int
    var program: Int          // General MIDI program 0-127 (0 for drums)
    var isDrums: Bool
    var trackName: String?
    var noteCount: Int
    var name: String { isDrums ? "Drums" : GM.names[min(max(program, 0), 127)] }
}

struct Note {
    var pitch: Int
    var start: Double      // seconds
    var duration: Double   // seconds
    var velocity: Int
    var part: Int          // index into Song.parts
    var end: Double { start + duration }
}

struct Song {
    var url: URL
    var notes: [Note]          // sorted by start
    var parts: [Part]
    var duration: Double       // seconds, end of the last note
    var minPitch: Int          // range of pitched (non-drum) notes
    var maxPitch: Int
    var maxDuration: Double

    /// Silence before the first note so notes can fall in from the top.
    static let leadIn: Double = 3.0
    /// Time after the last note so releases can ring out.
    static let tail: Double = 1.5
    /// Full length of the preview/video timeline.
    var totalDuration: Double { Song.leadIn + duration + Song.tail }
}

enum MIDIError: LocalizedError {
    case load(OSStatus)
    case noNotes
    var errorDescription: String? {
        switch self {
        case .load(let s): return "Could not read the MIDI file (error \(s))."
        case .noNotes: return "The MIDI file contains no notes."
        }
    }
}

enum MIDIParser {
    static func load(url: URL) throws -> Song {
        var seqOpt: MusicSequence?
        NewMusicSequence(&seqOpt)
        guard let seq = seqOpt else { throw MIDIError.load(-1) }
        defer { DisposeMusicSequence(seq) }

        let status = MusicSequenceFileLoad(seq, url as CFURL, .midiType, [])
        guard status == noErr else { throw MIDIError.load(status) }

        var trackCount: UInt32 = 0
        MusicSequenceGetTrackCount(seq, &trackCount)

        struct Raw { var pitch: Int; var beat: Double; var beats: Double; var vel: Int; var track: Int; var channel: Int }
        var raws: [Raw] = []
        var programChanges: [Int: [(beat: Double, program: Int)]] = [:]   // by channel
        var trackNames: [Int: String] = [:]

        for ti in 0..<trackCount {
            var trackOpt: MusicTrack?
            MusicSequenceGetIndTrack(seq, ti, &trackOpt)
            guard let track = trackOpt else { continue }
            var iterOpt: MusicEventIterator?
            NewMusicEventIterator(track, &iterOpt)
            guard let iter = iterOpt else { continue }
            defer { DisposeMusicEventIterator(iter) }

            var has: DarwinBoolean = false
            MusicEventIteratorHasCurrentEvent(iter, &has)
            while has.boolValue {
                var ts: MusicTimeStamp = 0
                var type: MusicEventType = 0
                var data: UnsafeRawPointer?
                var size: UInt32 = 0
                MusicEventIteratorGetEventInfo(iter, &ts, &type, &data, &size)
                if let data {
                    switch type {
                    case kMusicEventType_MIDINoteMessage:
                        let m = data.assumingMemoryBound(to: MIDINoteMessage.self).pointee
                        raws.append(Raw(pitch: Int(m.note), beat: ts, beats: Double(m.duration),
                                        vel: Int(m.velocity), track: Int(ti), channel: Int(m.channel)))
                    case kMusicEventType_MIDIChannelMessage:
                        let m = data.assumingMemoryBound(to: MIDIChannelMessage.self).pointee
                        if m.status & 0xF0 == 0xC0 {
                            programChanges[Int(m.status & 0x0F), default: []].append((ts, Int(m.data1)))
                        }
                    case kMusicEventType_Meta:
                        let m = data.assumingMemoryBound(to: MIDIMetaEvent.self).pointee
                        if m.metaEventType == 3, m.dataLength > 0, trackNames[Int(ti)] == nil,
                           let off = MemoryLayout<MIDIMetaEvent>.offset(of: \.data) {
                            let bytes = UnsafeBufferPointer(
                                start: data.advanced(by: off).assumingMemoryBound(to: UInt8.self),
                                count: Int(m.dataLength))
                            let s = String(decoding: bytes, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if !s.isEmpty { trackNames[Int(ti)] = s }
                        }
                    default: break
                    }
                }
                MusicEventIteratorNextEvent(iter)
                MusicEventIteratorHasCurrentEvent(iter, &has)
            }
        }
        guard !raws.isEmpty else { throw MIDIError.noNotes }
        for ch in programChanges.keys { programChanges[ch]!.sort { $0.beat < $1.beat } }

        // Group notes into parts by (track, channel, program in effect when the note starts).
        struct Key: Hashable, Comparable {
            var track: Int; var channel: Int; var program: Int
            static func < (a: Key, b: Key) -> Bool {
                (a.track, a.channel, a.program) < (b.track, b.channel, b.program)
            }
        }
        let keys: [Key] = raws.map { r in
            let isDrums = r.channel == 9
            let fileProgram = programChanges[r.channel]?.last(where: { $0.beat <= r.beat + 1e-6 })?.program
                ?? programChanges[r.channel]?.first?.program ?? 0
            // The track's name can say more than a vague or missing program ("Violas (section)" + String Ensemble).
            let prog = isDrums ? 0 : InstrumentRules.program(forTrackName: trackNames[r.track],
                                                             fileProgram: fileProgram,
                                                             explicit: programChanges[r.channel] != nil,
                                                             switchesProgram: Set(programChanges[r.channel]?.map(\.program) ?? []).count > 1)
            return Key(track: r.track, channel: r.channel, program: prog)
        }
        let orderedKeys = Array(Set(keys)).sorted()
        let index = Dictionary(uniqueKeysWithValues: orderedKeys.enumerated().map { ($1, $0) })
        var counts = [Int](repeating: 0, count: orderedKeys.count)

        var notes: [Note] = []
        notes.reserveCapacity(raws.count)
        for (i, r) in raws.enumerated() {
            let p = index[keys[i]]!
            counts[p] += 1
            var s = 0.0, e = 0.0
            MusicSequenceGetSecondsForBeats(seq, r.beat, &s)
            MusicSequenceGetSecondsForBeats(seq, r.beat + r.beats, &e)
            notes.append(Note(pitch: r.pitch, start: s, duration: max(e - s, 0.03), velocity: r.vel, part: p))
        }
        notes.sort { $0.start < $1.start }

        let parts = orderedKeys.enumerated().map { (i, k) in
            Part(track: k.track, channel: k.channel, program: k.program, isDrums: k.channel == 9,
                 trackName: trackNames[k.track], noteCount: counts[i])
        }
        let pitched = notes.filter { !parts[$0.part].isDrums }
        let range = pitched.isEmpty ? notes : pitched

        return Song(url: url,
                    notes: notes,
                    parts: parts,
                    duration: notes.map(\.end).max() ?? 0,
                    minPitch: range.map(\.pitch).min() ?? 60,
                    maxPitch: range.map(\.pitch).max() ?? 60,
                    maxDuration: notes.map(\.duration).max() ?? 0)
    }

    /// Builds a clean 120bpm MIDI file with one track per part (notes shifted by the lead-in).
    /// The audio engine plays this, so what you hear always matches what is drawn.
    static func playbackData(for song: Song) throws -> Data {
        var seqOpt: MusicSequence?
        NewMusicSequence(&seqOpt)
        guard let seq = seqOpt else { throw MIDIError.load(-1) }
        defer { DisposeMusicSequence(seq) }

        var tempoTrack: MusicTrack?
        MusicSequenceGetTempoTrack(seq, &tempoTrack)
        if let tempoTrack { MusicTrackNewExtendedTempoEvent(tempoTrack, 0, 120) }

        var tracks: [MusicTrack] = []
        for _ in song.parts {
            var trackOpt: MusicTrack?
            MusicSequenceNewTrack(seq, &trackOpt)
            guard let track = trackOpt else { throw MIDIError.load(-2) }
            tracks.append(track)
        }
        for n in song.notes {
            var msg = MIDINoteMessage(channel: 0, note: UInt8(n.pitch),
                                      velocity: UInt8(max(1, min(127, n.velocity))),
                                      releaseVelocity: 0, duration: Float32(n.duration * 2))
            MusicTrackNewMIDINoteEvent(tracks[n.part], (n.start + Song.leadIn) * 2, &msg)
        }
        var cf: Unmanaged<CFData>?
        let st = MusicSequenceFileCreateData(seq, .midiType, .eraseFile, 480, &cf)
        guard st == noErr, let data = cf?.takeRetainedValue() else { throw MIDIError.load(st) }
        return data as Data
    }
}
