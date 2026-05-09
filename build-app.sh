#!/usr/bin/env bash
# Build TermUsher.app bundle from the SPM binary.
# Run from project root.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="TermUsher"
APP_DIR="$APP_NAME.app"
VERSION="0.4.3"
BUILD="23"

echo "==> swift build (release, universal: arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

# When `--arch` is passed twice, SPM emits a universal binary at
# .build/apple/Products/Release/<name>. Single-arch builds end up at
# .build/release/<name>. Resolve whichever exists.
if [[ -f ".build/apple/Products/Release/$APP_NAME" ]]; then
    BIN_PATH=".build/apple/Products/Release/$APP_NAME"
else
    BIN_PATH=".build/release/$APP_NAME"
fi

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
    <string>TermUsher</string>
    <key>CFBundleIdentifier</key>
    <string>com.youngharold.termusher</string>
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
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key>
    <string>Local build</string>
</dict>
</plist>
PLIST

# Sign with the stable self-signed identity if it's set up. The stable identity
# makes macOS TCC (Accessibility, Login Items) keep its grant across rebuilds —
# without it, every new build looks like a "different app" to macOS and you have
# to re-grant Accessibility every time. Run ./scripts/setup-codesigning.sh once
# (plus the sudo trust step it prints) to enable.
#
# We check for the cert by certificate name, not `find-identity -v` — the latter
# is too conservative about self-signed identities even when they sign correctly.
SIGN_IDENTITY="TermUsher Self-Signed"
if security find-certificate -c "$SIGN_IDENTITY" >/dev/null 2>&1; then
    echo "==> Codesigning with stable identity: $SIGN_IDENTITY"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR"
else
    echo "==> Codesigning ad-hoc (run ./scripts/setup-codesigning.sh for stable signing)"
    codesign --force --deep --sign - "$APP_DIR"
fi

echo "==> Done: $(pwd)/$APP_DIR"
