#!/bin/sh
# Builds and runs the unit tests (no Bluetooth or audio hardware needed).
set -e
cd "$(dirname "$0")"
OUT="${TMPDIR:-/tmp}/bab-tests"
mkdir -p "$OUT"
cc -Wall -I../src -o "$OUT/test_avdtp_frame" test_avdtp_frame.c
clang -fobjc-arc -Wall -DBAB_TESTS -I../src -o "$OUT/test_player" test_player.m ../src/AACPlayer.m \
  -framework Foundation -framework AudioToolbox -framework CoreAudio
cc -Wall -I../src -o "$OUT/test_latm" test_latm.c ../src/latm.c
"$OUT/test_avdtp_frame"
"$OUT/test_player"
"$OUT/test_latm"
