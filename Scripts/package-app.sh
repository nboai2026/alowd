#!/usr/bin/env bash
# Packages Alowd as a standalone macOS app bundle at ./dist/Alowd.app.
# Builds in release mode, assembles the bundle, and ad-hoc codesigns it.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
APP_DIR="$DIST_DIR/Alowd.app"
VERSION="0.2.0"

echo "==> Building release binary"
swift build -c release --package-path "$REPO_ROOT"

BIN_PATH="$(swift build -c release --package-path "$REPO_ROOT" --show-bin-path)/AlowdApp"
if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/Alowd"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Alowd</string>
    <key>CFBundleIdentifier</key>
    <string>com.alowd.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Alowd</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Alowd records audio only while you dictate; everything is processed on-device.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Generating app icon"
if ! "$REPO_ROOT/Scripts/generate-app-icon.sh" "$APP_DIR/Contents/Resources" 2>/dev/null; then
    echo "    (icon generation unavailable; skipping icon)"
else
    /usr/bin/plutil -insert CFBundleIconFile -string "AppIcon" "$APP_DIR/Contents/Info.plist"
fi

echo "==> Codesigning (ad-hoc)"
codesign --force --deep -s - "$APP_DIR"

echo "==> Done: $APP_DIR"
codesign -dv "$APP_DIR" 2>&1 | head -3
