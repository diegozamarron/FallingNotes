#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Diego Zamarron
# Builds a static libx264 for Apple Silicon into ThirdParty/x264/{include,lib}.
# x264 is GPL-2.0-or-later, which is why Falling Notes as a whole is GPL-3.0-or-later (see LICENSE).
# Needs: git and clang (Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

# The exact x264 revision the app is built with (the "stable" branch, revision 3222).
X264_COMMIT=b35605ace3ddf7c1a5d67a2eb553f034aef41d55
SDK="$(xcrun --sdk macosx --show-sdk-path)"      # Xcode's SDK (the Command Line Tools one can be out of step)
SRC=ThirdParty/x264-src
OUT=ThirdParty/x264

if [ -f "$OUT/lib/libx264.a" ] && [ -f "$OUT/include/x264.h" ] && [ -z "${FORCE:-}" ]; then
  echo "libx264 already built ($OUT). Run with FORCE=1 to rebuild."
  exit 0
fi

mkdir -p ThirdParty
if [ ! -d "$SRC/.git" ]; then
  git clone --quiet https://code.videolan.org/videolan/x264.git "$SRC"
fi
git -C "$SRC" checkout --quiet "$X264_COMMIT"

build() {   # build <arch> <host triple>
  local arch="$1" host="$2"
  local dir="$PWD/ThirdParty/x264-build-$arch"
  rm -rf "$dir" && mkdir -p "$dir" && cd "$dir"
  CC="clang -arch $arch -isysroot $SDK -mmacosx-version-min=14.0" "$PWD/../x264-src/configure" \
    --host="$host" --enable-static --enable-pic --disable-cli --disable-opencl --disable-avs \
    --disable-swscale --disable-lavf --disable-ffms --disable-gpac --disable-lsmash \
    --bit-depth=8 --chroma-format=420 --prefix="$dir/install" >/dev/null
  make -j"$(sysctl -n hw.ncpu)" >/dev/null
  make install >/dev/null
  cd - >/dev/null
}

echo "Building x264 for arm64…"; build arm64 aarch64-apple-darwin

mkdir -p "$OUT/lib" "$OUT/include"
cp ThirdParty/x264-build-arm64/install/lib/libx264.a "$OUT/lib/libx264.a"
cp ThirdParty/x264-build-arm64/install/include/x264.h ThirdParty/x264-build-arm64/install/include/x264_config.h "$OUT/include/"
# the Swift package compiles against these copies (they are small and committed)
cp "$OUT/include/x264.h" "$OUT/include/x264_config.h" Sources/CX264/include/
echo "Built $OUT/lib/libx264.a ($(lipo -archs "$OUT/lib/libx264.a"))"
