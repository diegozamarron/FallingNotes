// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Diego Zamarron
import Foundation

/// Picks an instrument from a track's name when the file's own program number is vague or missing.
///
/// Many MIDI exports (MuseScore, notation programs, orchestral templates) tag every string section with
/// "String Ensemble 1" and only say what the part really is in its name: "Violas (section)", "Violoncellos…".
enum InstrumentRules {
    /// Keywords (matched anywhere in the lower-cased track name) and the General MIDI program (0-127) they mean.
    /// The first matching rule wins, so more specific names come before general ones
    /// ("electric piano" before "piano", "english horn" before "horn", "contrabass" before "bass").
    static let rules: [(keywords: [String], program: Int)] = [
        // Strings
        (["contrabass", "double bass", "doublebass", "string bass", "basses (section)"], 43),
        (["violoncello", "cello"], 42),
        (["viola"], 41),
        (["violin"], 40),
        (["fiddle"], 110),
        (["pizzicato", "pizz"], 45),
        (["tremolo"], 44),
        (["harp"], 46),
        (["timpani"], 47),
        // Keys
        (["electric piano", "e.piano", "e-piano", "epiano", "rhodes", "wurlitzer"], 4),
        (["honky"], 3),
        (["harpsichord", "cembalo"], 6),
        (["clavinet", "clavi"], 7),
        (["celesta"], 8),
        (["piano"], 0),
        (["church organ", "pipe organ"], 19),
        (["rock organ"], 18),
        (["organ"], 19),
        (["accordion"], 21),
        (["harmonica"], 22),
        // Woodwinds
        (["piccolo"], 72),
        (["flute"], 73),
        (["recorder"], 74),
        (["pan flute", "panflute"], 75),
        (["english horn", "cor anglais"], 69),
        (["oboe"], 68),
        (["bassoon", "fagott"], 70),
        (["clarinet"], 71),
        (["soprano sax"], 64),
        (["alto sax"], 65),
        (["tenor sax"], 66),
        (["baritone sax", "bari sax"], 67),
        (["sax"], 65),
        // Brass
        (["muted trumpet"], 59),
        (["trumpet", "cornet"], 56),
        (["trombone"], 57),
        (["tuba"], 58),
        (["french horn", "horn"], 60),
        (["brass"], 61),
        // Guitars and basses
        (["nylon", "classical guitar"], 24),
        (["steel guitar", "acoustic guitar"], 25),
        (["jazz guitar"], 26),
        (["clean guitar", "electric guitar"], 27),
        (["muted guitar"], 28),
        (["overdrive"], 29),
        (["distortion", "distorted"], 30),
        (["guitar"], 25),
        (["acoustic bass", "upright"], 32),
        (["fretless"], 35),
        (["slap bass"], 36),
        (["synth bass"], 38),
        (["bass guitar", "electric bass", "finger bass"], 33),
        (["bass"], 33),
        // Tuned percussion and others
        (["glockenspiel"], 9),
        (["music box"], 10),
        (["vibraphone", "vibes"], 11),
        (["marimba"], 12),
        (["xylophone"], 13),
        (["tubular", "chimes"], 14),
        (["banjo"], 105),
        (["sitar"], 104),
        (["koto"], 107),
        (["steel drum"], 114),
        // Voices
        (["choir", "chorus", "voices", "vocal"], 52),
        (["synth strings"], 50),
        (["string ensemble", "strings"], 48),
    ]

    /// Programs too vague to trust over a specific track name: the string ensembles and synth strings.
    static let vaguePrograms: Set<Int> = [48, 49, 50, 51]

    /// The instrument for a track.
    /// - `fileProgram`: the program number the file itself assigns.
    /// - `explicit`: whether the file sets a program at all for that channel (otherwise it's just the default piano).
    /// The name wins when the file gave no program or only a vague one; a specific program in the file is kept.
    static func program(forTrackName name: String?, fileProgram: Int, explicit: Bool) -> Int {
        guard !explicit || vaguePrograms.contains(fileProgram) else { return fileProgram }
        guard let match = match(name) else { return fileProgram }
        return match
    }

    static func match(_ name: String?) -> Int? {
        guard let lower = name?.lowercased(), !lower.isEmpty else { return nil }
        for rule in rules where rule.keywords.contains(where: { lower.contains($0) }) { return rule.program }
        return nil
    }
}
