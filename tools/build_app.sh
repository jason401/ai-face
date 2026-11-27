#!/bin/zsh
# Stage a complete signed bundle (AI Face.update.app) without touching the running app.
# No option: also install it, but only as a first installation (tools/first_install.py).
set -eu
cd "${0:A:h}/.."
MODE="${1:-}"
APP="AI Face.update.app"
LOG="app-build.log"
case "$MODE" in
  ""|--stage|--compile-only) ;;
  --prebuilt) exec /usr/bin/python3 tools/deploy_app.py --legacy ;;
  *) echo "Unknown build option: $MODE" >&2; exit 2 ;;
esac
xcode-select -p >/dev/null
IDENTITY="AI Face Local Signing"
security find-certificate -c "$IDENTITY" >/dev/null 2>&1 || {
  echo "Missing AI Face Local Signing identity; refusing ad-hoc signing. Run: zsh tools/setup_signing.sh" >&2; exit 1
}
STAGING="$(mktemp -d "$PWD/.aiface-build-XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
CANDIDATE="$STAGING/$APP"
mkdir -p "$CANDIDATE/Contents/MacOS" "$CANDIDATE/Contents/Helpers" "$CANDIDATE/Contents/Resources"
ARCH="${AIFACE_BUILD_ARCH:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 2 ;; esac
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" \
  -framework Cocoa -framework SwiftUI -framework ServiceManagement -framework EventKit -framework PDFKit -framework ScreenCaptureKit -framework CoreMedia \
  -o "$CANDIDATE/Contents/MacOS/AIFace" app/macos/*.swift >"$LOG" 2>&1
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" -framework Cocoa tools/install_bridge.swift \
  -o "$CANDIDATE/Contents/Helpers/InstallBridge" >>"$LOG" 2>&1
# AI Face Listener (Transcribe): an app of its own so that only it holds the microphone and system
# audio permissions. The process tap needs macOS 14.2.
LISTENER="$CANDIDATE/Contents/Helpers/AI Face Listener.app"
mkdir -p "$LISTENER/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos14.2" -framework Cocoa -framework AVFoundation -framework CoreAudio \
  -o "$LISTENER/Contents/MacOS/AIFaceListener" app/listener/*.swift >>"$LOG" 2>&1
cp -R app/macos/Resources/*.lproj "$CANDIDATE/Contents/Resources/"
# Copy only runtime resources, never the developer git checkout or tests.
mkdir -p "$CANDIDATE/Contents/Resources/core" "$CANDIDATE/Contents/Resources/tools"
cp core/*.py "$CANDIDATE/Contents/Resources/core/"
cp -R core/aiface "$CANDIDATE/Contents/Resources/core/"
find "$CANDIDATE" -name __pycache__ -type d -prune -exec rm -rf {} +
cp LICENSE THIRD_PARTY_NOTICES.md "$CANDIDATE/Contents/Resources/"
mkdir -p "$CANDIDATE/Contents/Resources/firmware"
cp -R firmware/ESP32_Display "$CANDIDATE/Contents/Resources/firmware/"
cp 'tools/Set up Keep Awake.command' 'tools/Remove Keep Awake.command' 'tools/Set up Transcription.command' "$CANDIDATE/Contents/Resources/tools/"
cp tools/install_app.py tools/deploy_app.py "$CANDIDATE/Contents/Resources/"
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s app/macos/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
  sips -z $((s * 2)) $((s * 2)) app/macos/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$CANDIDATE/Contents/Resources/AppIcon.icns" >>"$LOG" 2>&1
cat > "$CANDIDATE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIFace</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>CFBundleIdentifier</key><string>local.aiface</string>
<key>CFBundleName</key><string>AI Face</string>
<key>CFBundleDisplayName</key><string>AI Face</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>2.3.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSAppleEventsUsageDescription</key><string>AI Face reads your mail in the Mail app (read only) so the AI apps you allow (Settings → AI) can answer questions about it. It never sends, moves or deletes mail.</string>
<key>NSCalendarsFullAccessUsageDescription</key><string>AI Face reads your calendar so the AI apps you allow (Settings → AI) can answer questions about your schedule. It never changes events.</string>
<key>NSCalendarsUsageDescription</key><string>AI Face reads your calendar so the AI apps you allow (Settings → AI) can answer questions about your schedule. It never changes events.</string>
<!-- macOS may attribute a nested Listener's audio requests to the enclosing app bundle. -->
<key>NSMicrophoneUsageDescription</key><string>AI Face Listener transcribes microphone audio while you have Transcribe on. No audio is kept.</string>
<key>NSAudioCaptureUsageDescription</key><string>AI Face Listener transcribes the sound this Mac plays while you have Transcribe on. No audio is kept.</string>
</dict></plist>
PLIST
cat > "$LISTENER/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIFaceListener</string>
<key>CFBundleIdentifier</key><string>local.aiface.listener</string>
<key>CFBundleName</key><string>AI Face Listener</string>
<key>CFBundleDisplayName</key><string>AI Face Listener</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSMicrophoneUsageDescription</key><string>AI Face Listener writes down what you say, as text only, while you have Transcribe on in AI Face. No audio is kept.</string>
<key>NSAudioCaptureUsageDescription</key><string>AI Face Listener writes down what this Mac plays, as text only, while you have Transcribe on in AI Face. No audio is kept.</string>
</dict></plist>
PLIST
REVISION="$(git rev-parse HEAD)"
BUILD="$(git rev-list --count HEAD)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$CANDIDATE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AISourceRevision string $REVISION" "$CANDIDATE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :AISourceChannel string $(git rev-parse --abbrev-ref HEAD)" "$CANDIDATE/Contents/Info.plist"
# The Listener carries AI Face's version.
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$LISTENER/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CANDIDATE/Contents/Info.plist")" "$LISTENER/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$CANDIDATE/Contents/Helpers/InstallBridge" >>"$LOG" 2>&1
codesign --force --sign "$IDENTITY" "$LISTENER" >>"$LOG" 2>&1
codesign --force --sign "$IDENTITY" "$CANDIDATE" >>"$LOG" 2>&1
codesign --verify --deep --strict "$CANDIDATE" >>"$LOG" 2>&1
# Only the inactive candidate is replaced.
rm -rf "$APP"
mv "$CANDIDATE" "$APP"
echo "Staged $APP ($REVISION)"
if [ -z "$MODE" ]; then
  # Like AI Illuminati: an installed app changes only through its stable updates. A plain
  # build installs only on a Mac without AI Face in /Applications (first installation).
  # An AI Face signed on another Mac (the old ready-made download) is replaced; one signed with
  # this Mac's identity is left alone (tools/first_install.py).
  exec /usr/bin/python3 tools/first_install.py
fi
