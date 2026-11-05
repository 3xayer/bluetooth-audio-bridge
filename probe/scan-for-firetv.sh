#!/bin/sh
# Scans for nearby Bluetooth devices for ~30 s so we can check whether the Mac can see the Fire TV.
cd "$(dirname "$0")"
[ -d Probe.app ] || ./build.sh
echo "Put the Fire TV on: Settings > Controllers & Bluetooth Devices > Other Bluetooth Devices > Add Bluetooth Devices"
echo "Scanning for 30 s ..."
rm -f probe.log
open -W --stdout "$PWD/probe.log" --stderr "$PWD/probe.log" Probe.app --args --scan 30
grep -E "Found|Result|complete" probe.log
