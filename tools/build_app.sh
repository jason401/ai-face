#!/bin/zsh
# Builds "AI Face.app" (menu bar face + controller) from app/macos/main.m into the project
# folder, then starts it. Needs the Xcode Command Line Tools (clang). Run via 앱 빌드.command.
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
pkill -f "core/run_server.py --no-browser" 2>/dev/null
pkill -f "esp_display.py --no-browser" 2>/dev/null
# The ESP32-era app must not start at login any more (it would fight over the USB port).
OLD_AGENT="$HOME/Library/LaunchAgents/local.esp32.display.plist"
if [ -f "$OLD_AGENT" ]; then
  launchctl unload "$OLD_AGENT" >/dev/null 2>&1
  rm -f "$OLD_AGENT"
  echo "   예전 앱의 로그인 자동 실행을 껐습니다."
fi
sleep 1

echo "2/4 컴파일"
mkdir -p "$APP/Contents/MacOS"
if ! clang -fobjc-arc -O2 -mmacosx-version-min=11.0 -framework Cocoa \
      -o "$APP/Contents/MacOS/AIFace.new" app/macos/main.m >"$LOG" 2>&1; then
  echo
  echo "빌드 실패. 아래 내용(또는 app-build.log)을 Claude에게 알려 주세요."
  echo "------------------------------------------------------------"
  cat "$LOG"
  read "?엔터를 누르면 창이 닫힙니다."
  exit 1
fi
mv -f "$APP/Contents/MacOS/AIFace.new" "$APP/Contents/MacOS/AIFace"

echo "3/4 앱 정보와 서명"
# NSAllowsLocalNetworking: the menu bar face reads http://127.0.0.1 (the Python controller).
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AIFace</string>
<key>CFBundleIdentifier</key><string>local.aiface</string>
<key>CFBundleName</key><string>AI Face</string>
<key>CFBundleDisplayName</key><string>AI Face</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1.0</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>11.0</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >>"$LOG" 2>&1

echo "4/4 앱 실행"
echo "빌드 완료 $(date)" >>"$LOG"
open "$APP"
echo
echo "완료: 메뉴바 오른쪽 위에 동그란 얼굴이 생깁니다."
sleep 2
