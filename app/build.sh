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
  src/main.m src/AppDelegate.m src/SinkSession.m src/AACPlayer.m src/Log.m src/LinkPriority.m src/AVRCP.m src/MenuViews.m src/SystemVolume.m src/latm.c third_party/sbc/srce/*.c -Ithird_party/sbc/include \
  -framework Cocoa -framework IOBluetooth -framework CoreBluetooth \
  -framework AudioToolbox -framework CoreAudio -framework ServiceManagement -framework MediaPlayer

# Sign with the local self-signed identity if present (see make-signing-cert.sh): the code identity
# then stays the same across rebuilds, so macOS keeps the Bluetooth permission and login item.
# Falls back to ad-hoc signing.
CERT_NAME="Bluetooth Audio Bridge Local Signing"
CERT_SHA1=$(security find-certificate -c "$CERT_NAME" -Z 2>/dev/null | awk '/SHA-1 hash:/{print $3; exit}')
if [ -n "$CERT_SHA1" ] && codesign -s "$CERT_SHA1" -f "$APP" >/dev/null 2>&1; then
  echo "Signed with \"$CERT_NAME\""
else
  codesign -s - -f "$APP" >/dev/null 2>&1
  echo "Signed ad-hoc (run ./make-signing-cert.sh once for a stable signature)"
fi
echo "Built $(pwd)/$APP"

if [ "$1" = "install" ]; then
  pkill -x BluetoothAudioBridge 2>/dev/null && sleep 1 || true
  rm -rf "/Applications/Bluetooth Audio Bridge.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Bluetooth Audio Bridge.app"
  open "/Applications/Bluetooth Audio Bridge.app"
fi
