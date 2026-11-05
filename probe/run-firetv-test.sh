#!/bin/sh
# Live test with the Fire TV. Keeps the Mac discoverable (Bluetooth settings open),
# advertises it as a speaker for 120 s and logs any connection attempts.
cd "$(dirname "$0")"
[ -d Probe.app ] || ./build.sh
open "x-apple.systempreferences:com.apple.BluetoothSettings"
echo "Now on the Fire TV: Settings > Controllers & Bluetooth Devices > Other Bluetooth Devices > Add."
echo "Look for this Mac in the list and try to pair. Logging for 120 s to probe.log ..."
rm -f probe.log
open -W --stdout "$PWD/probe.log" --stderr "$PWD/probe.log" Probe.app --args 120
cat probe.log
