#!/bin/sh
# Builds Probe.app (its own bundle, so macOS asks *it* for Bluetooth permission).
set -e
cd "$(dirname "$0")"
APP=Probe.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string probe" "$APP/Contents/Info.plist" 2>/dev/null || true
clang -fobjc-arc -Wall -o "$APP/Contents/MacOS/probe" probe.m avdtp.m aacplayer.m latm.c -framework Foundation -framework IOBluetooth -framework CoreBluetooth -framework AudioToolbox -framework CoreAudio
codesign -s - -f "$APP"
echo "Built $APP   Run: open -W --stdout \$PWD/probe.log --stderr \$PWD/probe.log Probe.app --args [seconds] [--no-cod]"
