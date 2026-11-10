#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

APP_NAME="Plume"
VERSION="$(tr -d '[:space:]' < "$SCRIPT_DIR/VERSION")"
BUILD_DIR="$SCRIPT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building $APP_NAME v$VERSION with Swift..."
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "📦 Packaging $APP_BUNDLE (v$VERSION)..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"
if [ -f "$SCRIPT_DIR/Resources/AppIcon.icns" ]; then
    cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi
if [ -f "$SCRIPT_DIR/Resources/PlumeLogo.png" ]; then
    cp "$SCRIPT_DIR/Resources/PlumeLogo.png" "$APP_BUNDLE/Contents/Resources/PlumeLogo.png"
fi
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

DEV_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/' || true)
if [ -n "$DEV_ID" ]; then
    echo "🔏 Signing $APP_BUNDLE with $DEV_ID..."
    codesign --force --deep --options runtime --identifier com.pschaus.Plume --sign "$DEV_ID" "$APP_BUNDLE"
else
    echo "🔏 Ad-hoc signing $APP_BUNDLE..."
    codesign --force --deep --identifier com.pschaus.Plume --sign - "$APP_BUNDLE"
fi

# Install into /Applications if writable, otherwise ~/Applications
if [ -w "/Applications" ]; then
    INSTALL_DIR="/Applications"
else
    INSTALL_DIR="$HOME/Applications"
    mkdir -p "$INSTALL_DIR"
fi

# Stop any previous Plume instance (both /Applications and build/)
killall -9 Plume 2>/dev/null || true
pkill -9 -f "Plume.app/Contents/MacOS/Plume" 2>/dev/null || true

echo "🚀 Installing to $INSTALL_DIR/$APP_NAME.app..."
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INSTALL_DIR/$APP_NAME.app"

# Refresh LaunchServices icon registration
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

echo "💿 Building local DMG installer in dist-macos/Plume-macOS.dmg..."
DMG_STAGING="$BUILD_DIR/dmg-staging"
DIST_DIR="$SCRIPT_DIR/dist-macos"
rm -rf "$DMG_STAGING" "$DIST_DIR"
mkdir -p "$DMG_STAGING" "$DIST_DIR"
cp -R "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

DMG_TEMP="$BUILD_DIR/rw_Plume.dmg"
DMG_PATH="$DIST_DIR/Plume_${VERSION}_universal.dmg"
rm -f "$DMG_TEMP" "$DMG_PATH"
hdiutil detach "/Volumes/Plume" -quiet 2>/dev/null || true

hdiutil create -quiet -srcfolder "$DMG_STAGING" -volname "Plume" -fs HFS+ -fsargs "-c c=64,a=16,e=16" -format UDRW -size 35m "$DMG_TEMP"
DEV_NAME=$(hdiutil attach -readwrite -noverify -noautoopen -nobrowse "$DMG_TEMP" | grep -E '^/dev/' | sed 1q | awk '{print $1}')
MOUNT_DIR=$(hdiutil info | grep -E "${DEV_NAME}s" | awk '{print $3}' | xargs)
if [ -z "$MOUNT_DIR" ]; then
    MOUNT_DIR="/Volumes/Plume"
fi

cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns" 2>/dev/null || true
if [ -f "$SCRIPT_DIR/Resources/dmg_DS_Store" ]; then
    cp "$SCRIPT_DIR/Resources/dmg_DS_Store" "$MOUNT_DIR/.DS_Store"
fi
chmod -Rf go-w "$MOUNT_DIR" 2>/dev/null || true
SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
rm -rf "$MOUNT_DIR/.fseventsd" 2>/dev/null || true

hdiutil detach -quiet "$DEV_NAME"
hdiutil convert -quiet "$DMG_TEMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH"
rm -f "$DMG_TEMP"
cp "$DMG_PATH" "$DIST_DIR/Plume-macOS.dmg"

echo "✅ Installed at: $INSTALL_DIR/$APP_NAME.app"
echo "✅ DMG created at: $DIST_DIR/Plume-macOS.dmg"
