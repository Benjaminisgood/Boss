cd /Users/ben/Desktop/myapp/Ben/Boss
set -euo pipefail

xcodebuild -project Boss.xcodeproj -scheme Boss -configuration Release -sdk macosx build >/tmp/boss_build.log

SETTINGS=$(xcodebuild -project Boss.xcodeproj -scheme Boss -configuration Release -sdk macosx -showBuildSettings)
TARGET_BUILD_DIR=$(echo "$SETTINGS" | awk -F' = ' '/ TARGET_BUILD_DIR = / {print $2; exit}')
WRAPPER_NAME=$(echo "$SETTINGS" | awk -F' = ' '/ WRAPPER_NAME = / {print $2; exit}')
VERSION=$(echo "$SETTINGS" | awk -F' = ' '/ MARKETING_VERSION = / {print $2; exit}')

APP_PATH="$TARGET_BUILD_DIR/$WRAPPER_NAME"
STAGE_DIR="build/dmg-staging/Boss"
DMG_PATH="dist/Boss-${VERSION}-macOS.dmg"

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR" dist
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -sfn /Applications "$STAGE_DIR/Applications"

hdiutil create -volname "Boss" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "${DMG_PATH}.sha256"
