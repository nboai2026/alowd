#!/usr/bin/env bash
# Generates AppIcon.icns into the directory given as $1.
# Draws the Alowd mark with CoreGraphics (AlowdIcon.swift), then packs an icns.
# Exits non-zero if any tool is unavailable; callers may treat that as "skip icon".
set -euo pipefail

DEST_DIR="${1:?usage: generate-app-icon.sh <resources-dir>}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

command -v swift >/dev/null
command -v sips >/dev/null
command -v iconutil >/dev/null

cp "$(dirname "${BASH_SOURCE[0]}")/AlowdIcon.swift" "$WORK_DIR/icon.swift"

swift "$WORK_DIR/icon.swift" "$WORK_DIR/icon-1024.png"

ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
for px in 16 32 64 128 256 512; do
    sips -z "$px" "$px" "$WORK_DIR/icon-1024.png" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    double=$((px * 2))
    sips -z "$double" "$double" "$WORK_DIR/icon-1024.png" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$DEST_DIR/AppIcon.icns"
