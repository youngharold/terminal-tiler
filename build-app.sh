#!/usr/bin/env bash
# Build TerminalTiler.app bundle from the SPM binary.
# Run from project root.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TerminalTiler"
APP_DIR="$APP_NAME.app"
BIN_PATH=".build/release/$APP_NAME"
VERSION="0.2.4"
BUILD="6"

echo "==> swift build (release)"
swift build -c release

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>Terminal Tiler</string>
    <key>CFBundleIdentifier</key>
    <string>com.youngharold.terminal-tiler</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Local build</string>
</dict>
</plist>
PLIST

echo "==> Codesigning ad-hoc"
codesign --force --deep --sign - "$APP_DIR"

echo "==> Done: $(pwd)/$APP_DIR"
