#!/bin/bash
# Regenerates Resources/AppIcon.icns from Tools/make_icon.swift. build.sh copies the result into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
swiftc -O Tools/make_icon.swift -o "$WORK/make_icon"
"$WORK/make_icon" "$WORK/icon_1024.png"

ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET" Resources
for s in 16 32 128 256 512; do
  sips -z $s $s "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$WORK/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
rm -rf "$WORK"
echo "Wrote Resources/AppIcon.icns"
