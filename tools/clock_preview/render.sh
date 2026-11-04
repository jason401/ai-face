#!/bin/zsh
# PNG previews of the clock designs, one contact sheet: zsh tools/clock_preview/render.sh <dir> [HH:MM:SS]
# Needs the Adafruit GFX library (Arduino IDE libraries folder or ADAFRUIT_GFX).
set -eu
HERE="${0:A:h}"; ROOT="${HERE:h:h}"
GFX="${ADAFRUIT_GFX:-$HOME/Documents/Arduino/libraries/Adafruit_GFX_Library}"
OUT="${1:-/tmp/aiface-clocks}"; mkdir -p "$OUT"
WORK=$(mktemp -d /tmp/aiface-clock-render.XXXXXX); trap 'rm -rf "$WORK"' EXIT
c++ -std=c++17 -O1 -w -DARDUINO=100 -I"$HERE/shim" -I"$GFX" -I"$ROOT/firmware/ESP32_Display" \
  "$GFX/Adafruit_GFX.cpp" "$HERE/render.cpp" -o "$WORK/render"
"$WORK/render" "$WORK" "${2:-10:09:37}"
for p in "$WORK"/*.ppm; do sips -s format png "$p" --out "$OUT/$(basename "${p%.ppm}").png" >/dev/null; done
echo "Previews in $OUT"
