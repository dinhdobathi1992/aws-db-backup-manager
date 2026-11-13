#!/usr/bin/env bash
# Build the native SwiftUI app as a universal binary and wrap it in an
# ad-hoc signed "AWS DB Backup Manager.app" under macos/build/.
set -euo pipefail

MACOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
APP_NAME="AWS DB Backup Manager"
EXECUTABLE="ADBMApp"
BUNDLE_ID="com.dinhdobathi.awsdbbackupmanager"
VERSION="0.2.0"
ICON_SRC="$REPO_DIR/build/appicon.png"
OUT_DIR="$MACOS_DIR/build"
APP="$OUT_DIR/$APP_NAME.app"

cd "$MACOS_DIR"
swift build -c release --arch arm64 --arch x86_64 --product "$EXECUTABLE"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --product "$EXECUTABLE" --show-bin-path)"
BIN="$BIN_DIR/$EXECUTABLE"
[ -x "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$EXECUTABLE"

ICON_PLIST=""
if [ -f "$ICON_SRC" ]; then
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    ICONSET="$WORK/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z "$double" "$double" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    ICON_PLIST="    <key>CFBundleIconFile</key>
    <string>AppIcon</string>"
else
    echo "warning: $ICON_SRC not found; building without an app icon" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
$ICON_PLIST
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

codesign --force --deep --sign - "$APP"
codesign --verify --strict "$APP"

echo "$APP"
