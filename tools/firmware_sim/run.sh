#!/bin/bash
# Compile the firmware on this computer against stub Arduino/Adafruit/LittleFS APIs
# and run the simulator tests. Needs a C++ compiler (c++ / clang++ / g++).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${TMPDIR:-/tmp}/aiface-firmware-sim"
CXX="${CXX:-c++}"
mkdir -p "$OUT"
cp "$HERE"/stub.h "$HERE"/test_*.cpp "$OUT"/
python3 "$HERE/mkfw.py" "$ROOT/firmware/ESP32_Display/ESP32_Display.ino" "$OUT/fw.cpp"
cd "$OUT"
for t in test_core test_fire test_notice test_style; do
  "$CXX" -std=c++17 -O1 -w -o "$t" "$t.cpp"
  echo "== $t"
  "./$t"
done
echo "firmware simulator: OK"
