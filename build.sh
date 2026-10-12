#!/bin/bash
# Builds build/Headroom.app. `./build.sh install` also copies it to ~/Applications and starts it.
set -euo pipefail
cd "$(dirname "$0")"

# Plain swiftc instead of SwiftPM: the Command Line Tools alone are enough, no Xcode needed.
mkdir -p build
BIN=build/Headroom-bin
swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" Sources/Headroom/*.swift -o "$BIN"

APP=build/Headroom.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headroom"
cp Resources/Info.plist "$APP/Contents/Info.plist"

ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
"$BIN" --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
  DEST="$HOME/Applications/Headroom.app"
  pkill -x Headroom 2>/dev/null && sleep 1 || true
  mkdir -p "$HOME/Applications"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installed to $DEST"
fi
