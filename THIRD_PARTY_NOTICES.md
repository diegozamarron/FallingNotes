# Notices

## Falling Notes

Copyright (C) 2026 Diego Zamarron

Falling Notes is free software: you can redistribute it and/or modify it under the terms of the GNU General Public
License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later
version. It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License (`LICENSE`) for
more details.

# Third-party software

## x264 — GPL-2.0-or-later

Falling Notes links the **x264** video encoder (https://www.videolan.org/developers/x264.html), which is licensed under
the GNU General Public License, version 2 or (at your option) any later version. Copyright (C) 2003-2025 x264 project.

Because x264 is linked into the app, Falling Notes as a whole is distributed under the **GNU General Public License,
version 3 or later** (see `LICENSE`), which is compatible with x264's "version 2 or later" terms.

- Version used: x264 `stable` branch, revision 3222, commit `b35605ace3ddf7c1a5d67a2eb553f034aef41d55`.
- Source: https://code.videolan.org/videolan/x264 at that commit. The exact source archive used for each release is
  attached to that release on GitHub (`x264-b35605a-source.tar.gz`).
- How it is built: `Tools/build_x264.sh` (a static, 8-bit Apple Silicon library with no changes to x264's source).

## Apple system frameworks

AVFoundation, VideoToolbox, CoreMIDI/AudioToolbox, Accelerate and SwiftUI are provided by macOS and are not distributed
with this app.
