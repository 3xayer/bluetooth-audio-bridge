#!/bin/sh
# Builds "Bluetooth Audio Bridge.app" with clang (no Xcode project needed).
#   ./build.sh            build into ./build
#   ./build.sh install    build and copy to /Applications
set -e
cd "$(dirname "$0")"
APP="build/Bluetooth Audio Bridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"

clang -fobjc-arc -O2 -Wall -Wno-unused-function -mmacosx-version-min=13.0 \
  -o "$APP/Contents/MacOS/BluetoothAudioBridge" \
  src/main.m src/AppDelegate.m src/SinkSession.m src/AACPlayer.m src/Log.m src/latm.c \
  -framework Cocoa -framework IOBluetooth -framework CoreBluetooth \
  -framework AudioToolbox -framework CoreAudio -framework ServiceManagement

codesign -s - -f "$APP" >/dev/null 2>&1
echo "Built $(pwd)/$APP"

if [ "$1" = "install" ]; then
  pkill -x BluetoothAudioBridge 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Bluetooth Audio Bridge.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Bluetooth Audio Bridge.app"
fi
