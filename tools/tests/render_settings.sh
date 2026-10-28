#!/bin/zsh
# Render settings tabs (English and Korean, light and dark) to PNGs for a visual check.
set -eu
cd "${0:A:h}/../.."
WORK=$(mktemp -d /tmp/aiface-settings-render.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
OUTPUT="${1:-/tmp/aiface-settings-previews}"
SOURCES=()
for SOURCE in app/macos/*.swift; do
  [[ "$SOURCE" == app/macos/main.swift ]] && continue
  SOURCES+=("$SOURCE")
done
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos13.0" -module-cache-path "$WORK/cache" \
  -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework EventKit \
  -o "$WORK/render" "${SOURCES[@]}" tools/tests/render_settings.swift
# Localizable.strings next to the binary, so L() finds them as in the app bundle.
cp -R app/macos/Resources/*.lproj "$WORK/"
for LANG_CODE in en ko; do
  "$WORK/render" "$OUTPUT" -AppleLanguages "($LANG_CODE)"
done
echo "Previews in $OUTPUT"
