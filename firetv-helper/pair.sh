#!/bin/sh
# One-time pairing of a Fire TV with this Mac, driven over ADB (the Fire TV's own Bluetooth menu
# hides computers, so the pairing is started from a tiny helper app instead).
#
#   ./pair.sh <fire-tv-ip>
#
# Needs: ADB debugging enabled on the Fire TV (Settings > My Fire TV > Developer options),
#        adb on this Mac (brew install android-platform-tools).
set -e
cd "$(dirname "$0")"
IP="$1"
[ -n "$IP" ] || { echo "usage: $0 <fire-tv-ip>"; exit 1; }
export ANDROID_SERIAL="$IP:5555"

MAC_BT=$(system_profiler SPBluetoothDataType 2>/dev/null | awk '/Bluetooth Controller:/{f=1} f&&/Address:/{print $2; exit}')
[ -n "$MAC_BT" ] || { echo "Could not read this Mac's Bluetooth address"; exit 1; }
echo "Mac Bluetooth address: $MAC_BT"

adb connect "$IP:5555" >/dev/null
echo "If the TV asks 'Allow USB debugging?', choose Always allow + OK."
adb wait-for-device

[ -f helper.apk ] || ./build.sh
adb install -r helper.apk >/dev/null
echo "Helper installed. Starting pairing - confirm the code on BOTH the TV and the Mac."
open "x-apple.systempreferences:com.apple.BluetoothSettings"
adb logcat -c
adb shell am start -n local.btbridge.helper/.MainActivity --es addr "$MAC_BT" --es cmd bond --ei seconds 60 >/dev/null

for i in $(seq 1 45); do
  sleep 2
  out=$(adb logcat -d -s 'BTBridge:*' | grep -E 'BONDED|-> NONE' || true)
  [ -n "$out" ] && break
done
adb logcat -d -s 'BTBridge:*' | grep BTBridge | sed 's/^.*BTBridge: /  /'
case "$out" in
  *BONDED*) echo "Paired. Start 'Bluetooth Audio Bridge' on the Mac." ;;
  *) echo "Pairing did not complete. Check the code prompts and try again." ; exit 1 ;;
esac
