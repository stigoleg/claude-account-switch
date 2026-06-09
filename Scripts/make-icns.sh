#!/usr/bin/env bash
# Convert AppBundle/AppIcon.png (1024×1024) into AppBundle/AppIcon.icns via
# `sips` (built-in) and `iconutil` (built-in, ships with macOS).
#
# Usage: ./Scripts/make-icns.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="AppBundle/AppIcon.png"
ICONSET="AppBundle/AppIcon.iconset"
ICNS="AppBundle/AppIcon.icns"

if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC not found — run \`swift Scripts/generate-icon.swift\` first." >&2
    exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# Standard macOS app-icon sizes per Apple's HIG (1x and 2x).
sips -z 16   16   "$SRC" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32   32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32   32   "$SRC" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64   64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128  128  "$SRC" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$SRC" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$SRC" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$SRC" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$SRC" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$SRC"                "$ICONSET/icon_512x512@2x.png"

iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

echo "wrote $ICNS"
