#!/bin/bash
set -euo pipefail

APP_NAME="MusicPlayer"
BUILD_DIR=".build/app"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "==> Building release binary..."
swift build -c release --arch arm64 2>&1
swift build -c release --arch x86_64 2>&1 || true

# Determine which arch binary we have
if [ -f ".build/arm64-apple-macosx/release/$APP_NAME" ]; then
    BINARY_PATH=".build/arm64-apple-macosx/release/$APP_NAME"
else
    BINARY_PATH=".build/release/$APP_NAME"
fi

echo "==> Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy app icon
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>MusicPlayer</string>
    <key>CFBundleIdentifier</key>
    <string>com.musicplayer.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MusicPlayer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleDisplayName</key>
    <string>MusicPlayer</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST

echo "==> Done: $APP_BUNDLE"
echo "    Open with: open $APP_BUNDLE"
