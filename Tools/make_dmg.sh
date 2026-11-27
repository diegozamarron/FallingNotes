#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Diego Zamarron
# Builds FallingNotes.app (Apple Silicon) and packs it into dist/FallingNotes-<version>.dmg: a disk image whose
# window shows the app and an Applications shortcut over background art in the app's style.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh
VERSION="$(cat VERSION)"
DMG="dist/FallingNotes-$VERSION.dmg"

# dmgbuild (a small Python tool) writes the window layout without scripting Finder. It is installed once, into
# ThirdParty/dmg-venv, the first time this runs.
VENV=ThirdParty/dmg-venv
if [ ! -x "$VENV/bin/dmgbuild" ]; then
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet dmgbuild
fi

# Background art, drawn at 1x and 2x and combined so it is sharp on Retina displays.
ART="$(mktemp -d)"
trap 'rm -rf "$ART"' EXIT
swiftc -O Tools/make_dmg_background.swift -o "$ART/make_bg"
"$ART/make_bg" "$ART/bg.png" 1 "$VERSION" >/dev/null
"$ART/make_bg" "$ART/bg@2x.png" 2 "$VERSION" >/dev/null
sips -s format tiff "$ART/bg.png" --out "$ART/bg1.tiff" >/dev/null
sips -s format tiff "$ART/bg@2x.png" --out "$ART/bg2.tiff" >/dev/null
tiffutil -cathidpicheck "$ART/bg1.tiff" "$ART/bg2.tiff" -out "$ART/background.tiff" >/dev/null

mkdir -p dist
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s Tools/dmg_settings.py \
  -D app=FallingNotes.app -D background="$ART/background.tiff" -D icon=Resources/AppIcon.icns \
  "Falling Notes" "$DMG" >/dev/null

# dmgbuild leaves Finder metadata (com.apple.FinderInfo) on the app folder, which makes its code signature fail
# to verify ("detritus not allowed") and could make macOS call the app damaged. Strip it, then recompress.
RW="$ART/writable.dmg"
hdiutil detach "/Volumes/Falling Notes" -quiet 2>/dev/null || true
hdiutil convert "$DMG" -format UDRW -o "$RW" >/dev/null
MOUNT="$(hdiutil attach "$RW" -nobrowse -noautoopen | tail -1 | awk -F'\t' '{print $NF}')"
xattr -cr "$MOUNT/FallingNotes.app"
codesign --verify --deep --strict "$MOUNT/FallingNotes.app"      # fail the build if the signature is still bad
hdiutil detach "$MOUNT" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

echo "Built $DMG"
shasum -a 256 "$DMG"
