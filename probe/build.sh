#!/bin/sh
# Builds Probe.app (its own bundle, so macOS asks *it* for Bluetooth permission).
set -e
cd "$(dirname "$0")"
APP=Probe.app
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string probe" "$APP/Contents/Info.plist" 2>/dev/null || true
clang -fobjc-arc -Wall -o "$APP/Contents/MacOS/probe" probe.m avdtp.m aacplayer.m latm.c trigger.m -framework Foundation -framework IOBluetooth -framework CoreBluetooth -framework AudioToolbox -framework CoreAudio -framework CoreWLAN -framework IOKit
# Same local identity as the app (see app/make-signing-cert.sh), so the Bluetooth permission survives rebuilds.
IDENTITY="Bluetooth Audio Bridge Local Signing"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    codesign -s "$IDENTITY" -f "$APP"
else
    codesign -s - -f "$APP"
fi
echo "Built $APP   Run: open -W --stdout \$PWD/probe.log --stderr \$PWD/probe.log Probe.app --args [seconds] [--no-cod]"
