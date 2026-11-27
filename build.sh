#!/bin/bash
# Builds FallingNotes and wraps it into FallingNotes.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
Tools/build_x264.sh                    # the encoder library (skipped if already built)
VERSION="$(cat VERSION)"
# UNIVERSAL=1 builds for both Apple Silicon and Intel (used for releases); the default builds for this Mac only.
ARCHS=()
[ "${UNIVERSAL:-0}" = "1" ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/FallingNotes"
APP="FallingNotes.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FallingNotes"
# Licence and third-party notices travel with the app (GPL requires this)
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# App icon (regenerate with Tools/make_icon.sh)
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>FallingNotes</string>
  <key>CFBundleIdentifier</key><string>com.local.FallingNotes</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleName</key><string>FallingNotes</string>
  <key>CFBundleDisplayName</key><string>Falling Notes</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>MIDI File</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>CFBundleTypeExtensions</key><array><string>mid</string><string>midi</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
xattr -cr "$APP"                       # stray metadata (e.g. com.apple.provenance) breaks the signature
codesign --force --sign - "$APP"
# macOS can re-add that metadata a moment after files are written, so retry before complaining.
for attempt in 1 2 3; do
  xattr -cr "$APP"
  codesign --verify --deep --strict "$APP" 2>/dev/null && break
  [ "$attempt" = 3 ] && echo "warning: the signature didn't verify (stray file attributes?); the DMG copy is made without them"
  sleep 0.3
done
echo "Built $APP"
