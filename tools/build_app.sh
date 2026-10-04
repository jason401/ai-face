#!/bin/zsh
# Builds "AI Face.app" (menu bar face + settings window) from app/macos/*.swift into the
# project folder, then starts it. Needs the Xcode Command Line Tools (swiftc). Run via 앱 빌드.command.
cd "${0:A:h}/.." || exit 1
APP="AI Face.app"
LOG="app-build.log"
echo "AI Face 앱 빌드"
echo
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools가 필요합니다. 설치 창이 뜨면 설치한 뒤 다시 실행하세요."
  xcode-select --install
  read "?엔터를 누르면 창이 닫힙니다."
  exit 1
fi

echo "1/4 실행 중인 앱 종료 (예전 ESP32 Controller 포함)"
for id in local.aiface local.esp32.display; do
  osascript -e "tell application id \"$id\" to quit" >/dev/null 2>&1
done
sleep 1
pkill -f "AI Face.app/Contents/MacOS/" 2>/dev/null
pkill -f "ESP32 Controller.app/Contents/MacOS/launch" 2>/dev/null
pkill -f "core/run_server.py" 2>/dev/null
pkill -f "esp_display.py --no-browser" 2>/dev/null
# The ESP32-era app must not start at login any more (it would fight over the USB port).
OLD_AGENT="$HOME/Library/LaunchAgents/local.esp32.display.plist"
if [ -f "$OLD_AGENT" ]; then
  launchctl unload "$OLD_AGENT" >/dev/null 2>&1
  rm -f "$OLD_AGENT"
  echo "   예전 앱의 로그인 자동 실행을 껐습니다."
fi
sleep 1

echo "2/4 컴파일 (30초쯤 걸려요)"
mkdir -p "$APP/Contents/MacOS"
ARCH="$(uname -m)"
if ! xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" \
      -framework Cocoa -framework SwiftUI \
      -o "$APP/Contents/MacOS/AIFace.new" app/macos/*.swift >"$LOG" 2>&1; then
  echo
  echo "빌드 실패. 아래 내용(또는 app-build.log)을 Claude에게 알려 주세요."
  echo "------------------------------------------------------------"
  cat "$LOG"
  read "?엔터를 누르면 창이 닫힙니다."
  exit 1
fi
mv -f "$APP/Contents/MacOS/AIFace.new" "$APP/Contents/MacOS/AIFace"
# Translations (Localizable.strings per language): the app follows the Mac's language.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"
cp -R app/macos/Resources/*.lproj "$APP/Contents/Resources/"

echo "3/4 앱 정보와 서명"
# NSAllowsLocalNetworking: the menu bar face reads http://127.0.0.1 (the Python controller).
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIFace</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
<key>CFBundleIdentifier</key><string>local.aiface</string>
<key>CFBundleName</key><string>AI Face</string>
<key>CFBundleDisplayName</key><string>AI Face</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >>"$LOG" 2>&1

echo "4/4 앱 실행"
echo "빌드 완료 $(date)" >>"$LOG"
open "$APP"
echo
echo "완료: 메뉴바 오른쪽 위의 얼굴을 누르면 메뉴가, 설정…을 누르면 설정 창이 열려요."
sleep 2
