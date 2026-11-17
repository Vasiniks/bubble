#!/bin/bash
set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$DIR"

echo "==> Building Bubble (Release)..."
swift build -c release

APP_NAME="Bubble.app"
CONTENTS_DIR="$APP_NAME/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"

echo "==> Packaging $APP_NAME..."
rm -rf "$APP_NAME"
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$FRAMEWORKS_DIR"

# Copy binary
cp ".build/release/Bubble" "$MACOS_DIR/Bubble"
chmod +x "$MACOS_DIR/Bubble"

# Now Playing bridge: a tiny dylib Bubble runs inside /usr/bin/perl while the Music tab is open.
echo "==> Building media bridge..."
clang -dynamiclib -O2 -fobjc-arc -mmacosx-version-min=14.0 \
    -framework Foundation -framework ImageIO -framework CoreGraphics \
    -o "$FRAMEWORKS_DIR/MediaBridge.dylib" Sources/MediaBridge/MediaBridge.m

# App icon, if one has been generated (see docs/logos).
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
fi

# Create Info.plist
cat << 'EOF' > "$CONTENTS_DIR/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>Bubble</string>
    <key>CFBundleIdentifier</key>
    <string>com.eason.bubble</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleName</key>
    <string>Bubble</string>
    <key>CFBundleDisplayName</key>
    <string>Bubble</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Bubble's music controls play, pause and skip in the app or browser tab you pick, and take you to the tab that's playing.</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc sign bundle
echo "==> Signing $APP_NAME..."
codesign --force --sign - "$FRAMEWORKS_DIR/MediaBridge.dylib" 2>/dev/null || true
# The Apple Events entitlement lets macOS ask whether Bubble may switch browser tabs; without it
# the request is refused silently.
codesign --force --sign - --entitlements Bubble.entitlements "$APP_NAME"

echo "==> Successfully created $APP_NAME!"

case "$1" in
    run)
        echo "==> Launching Bubble..."
        open "$APP_NAME"
        ;;
    install)
        DEST="/Applications/$APP_NAME"
        echo "==> Installing to $DEST..."
        # Quit a running copy so the bundle can be replaced cleanly.
        pkill -x Bubble 2>/dev/null && sleep 1 || true
        rm -rf "$DEST"
        cp -R "$APP_NAME" "$DEST"
        open "$DEST"
        echo "==> Bubble is running. Hover or click the notch to open it, or press ⌃⌥⌘B."
        ;;
esac
