#!/bin/bash
# Builds ClassHours.app and ad-hoc signs it with the sandbox + calendar
# entitlements. No Xcode project needed -- swiftc assembles the bundle directly.
#
#   ./build.sh                build, then replace /Applications/ClassHours.app
#   ./build.sh --no-install   build into build/ only
#
# Installing is the default: the app lives in /Applications, so a build that
# didn't land there would just be a stale copy waiting to confuse someone.
set -euo pipefail
cd "$(dirname "$0")"

APP="ClassHours"
BUNDLE="build/$APP.app"
INSTALL_DIR="/Applications"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

swiftc \
  -swift-version 5 \
  -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -framework SwiftUI -framework EventKit -framework AppKit \
  -o "$BUNDLE/Contents/MacOS/$APP" \
  Sources/*.swift

cp Resources/Info.plist "$BUNDLE/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

codesign --force --sign - \
  --entitlements Resources/ClassHours.entitlements \
  "$BUNDLE"

echo "Built $BUNDLE"

if [ "${1:-}" != "--no-install" ]; then
  pkill -x "$APP" 2>/dev/null || true
  sleep 1
  rm -rf "$INSTALL_DIR/$APP.app"
  cp -R "$BUNDLE" "$INSTALL_DIR/$APP.app"
  echo "Installed $INSTALL_DIR/$APP.app"
fi
