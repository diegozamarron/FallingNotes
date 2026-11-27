# Falling Notes

A native macOS app that turns a MIDI file into a Synthesia-style "falling notes" video. Open a song, preview it,
adjust how each instrument looks and sounds, and export an `.mp4` or `.mov`.

## Features

- **Fast export** — H.264 exports use the Mac's hardware video encoder *and* the CPU at the same time (the video is cut into 8-second pieces, each encoded by whichever is free, then joined without re-encoding), about twice as fast as the hardware encoder alone. Pieces are cached, so re-exporting after changing only the audio, or only some instruments, reuses what didn't change. Turn off **Fast encoding** for a file made by a single encoder.
- **Preview and export** — notes fall onto an 88-key piano; export at 720p, 1080p, 4K or vertical 1080×1920, 30 or 60 fps, H.264 or HEVC, with audio. Shows an estimated size before exporting and the time remaining while it renders.
- **Real instruments** — each instrument is read from the MIDI file and played with the macOS General MIDI sounds, or any SoundFont (`.sf2`) / DLS file you choose. If a file only labels its tracks by name ("Violas (section)"), the name decides the instrument (see `InstrumentRules.swift`).
- **Per-instrument control** — colour, volume (0–150%, type an exact value), mute the sound, and show / fade into the background / hide the notes. These are independent, so you can hear an instrument without seeing it, or the other way round.
- **Select and group** — tick several instruments to change them together, or group them (by hand or **Auto-group** by family). A group's volume keeps the balance between its members.
- **Colour palette** — Synthesia-style green and blue, with a coral orange as the third colour.

## Install

Download the latest `FallingNotes-x.y.z.dmg` from [Releases](https://github.com/diegozamarron/FallingNotes/releases),
open it, and drag **FallingNotes** onto **Applications**. Works on Apple Silicon and Intel Macs running macOS 14 or later.

The app isn't signed with a paid Apple Developer certificate, so the first time you open it macOS will say it can't
check it for malware. Either open **System Settings → Privacy & Security**, scroll down and click **Open Anyway**,
or run `xattr -dr com.apple.quarantine /Applications/FallingNotes.app` once.

## Build

Requires macOS 14+ and Xcode (or the Swift toolchain).

```sh
./build.sh          # builds FallingNotes.app (ad-hoc signed, runs on the machine that built it)
open FallingNotes.app
```

To regenerate the app icon: `Tools/make_icon.sh`.

To make a release: bump `VERSION`, run `Tools/make_dmg.sh` (builds a universal app and `dist/FallingNotes-<version>.dmg`),
then `gh release create v<version> dist/FallingNotes-<version>.dmg`.

## Use

Open a `.mid` file with ⌘O or drag it onto the window. Space plays and pauses.

For scripted exports without the window:

```sh
FallingNotes.app/Contents/MacOS/FallingNotes --export in.mid out.mp4 \
    [--res 720|1080|2160|vertical] [--fps 30|60] [--hevc] [--silent] \
    [--mute 0,2] [--hide 1] [--faint 3] [--volume 0=0.5,1=1.2] [--soundfont file.sf2] \
    [--hybrid [--hw 1] [--sw 2] [--segment 8] [--no-cache]]
```

The numbers are instrument positions in the list the command prints.

## Layout

| File | What it does |
| --- | --- |
| `MIDIParser.swift`, `InstrumentRules.swift` | Reads notes and instruments; picks instruments from track names |
| `Renderer.swift` | Draws one frame (shared by the preview and the export) |
| `FrameView.swift` | Fast preview surface |
| `AudioEngine.swift` | One sampler per instrument; live and offline playback |
| `Exporter.swift` | Single-encoder video + audio export with `AVAssetWriter` (the fallback) |
| `SegmentedExporter.swift` | Fast export: hardware + software encoders in parallel, segment cache, lossless join |
| `AppModel.swift`, `Groups.swift` | App state, selection and groups |
| `Views.swift`, `Sidebar.swift` | The interface |
