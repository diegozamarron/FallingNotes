#!/bin/bash
# Builds a universal FallingNotes.app and packs it into dist/FallingNotes-<version>.dmg
# (a disk image with the app and an Applications shortcut to drag it onto).
set -euo pipefail
cd "$(dirname "$0")/.."

UNIVERSAL=1 ./build.sh
VERSION="$(cat VERSION)"
DMG="dist/FallingNotes-$VERSION.dmg"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
ditto --noextattr --noqtn FallingNotes.app "$STAGE/FallingNotes.app"   # copy without extended attributes
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f "$DMG"
hdiutil create -volname "Falling Notes" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG" >/dev/null

echo "Built $DMG"
shasum -a 256 "$DMG"
