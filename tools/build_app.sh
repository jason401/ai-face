#!/bin/zsh
# Builds "AI Face.app" (menu bar face + settings window) from app/macos/*.swift into the
# project folder, then starts it. Needs the Xcode Command Line Tools (swiftc). Run via "Build AI Face.command".
cd "${0:A:h}/.." || exit 1
APP="AI Face.app"
LOG="app-build.log"
# Messages in Korean when the Mac's first language is Korean, else English (like the app).
if defaults read -g AppleLanguages 2>/dev/null | sed -n 2p | grep -q '"\{0,1\}ko'; then KO=1; else KO=; fi
msg() { if [ -n "$KO" ]; then echo "$1"; else echo "$2"; fi }
ask() { if [ -n "$KO" ]; then read "?엔터를 누르면 창이 닫힙니다."; else read "?Press Return to close."; fi }
msg "AI Face 앱 빌드" "Building AI Face"
echo
if ! xcode-select -p >/dev/null 2>&1; then
  msg "Xcode Command Line Tools가 필요합니다. 설치 창이 뜨면 설치한 뒤 다시 실행하세요." \
      "The Xcode Command Line Tools are needed. Install them from the window that opens, then run this again."
  xcode-select --install
  ask
  exit 1
fi

msg "1/4 실행 중인 앱 종료 (예전 ESP32 Controller 포함)" "1/4 Quitting the running app (and the old ESP32 Controller)"
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
  msg "   예전 앱의 로그인 자동 실행을 껐습니다." "   The old app no longer opens at login."
fi
sleep 1

msg "2/4 컴파일 (30초쯤 걸려요)" "2/4 Compiling (about 30 seconds)"
mkdir -p "$APP/Contents/MacOS"
ARCH="$(uname -m)"
if ! xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos13.0" \
      -framework Cocoa -framework SwiftUI \
      -o "$APP/Contents/MacOS/AIFace.new" app/macos/*.swift >"$LOG" 2>&1; then
  echo
  msg "빌드 실패. 아래 내용(또는 app-build.log)을 Claude에게 알려 주세요." \
      "Build failed. The details are below (and in app-build.log)."
  echo "------------------------------------------------------------"
  cat "$LOG"
  ask
  exit 1
fi
mv -f "$APP/Contents/MacOS/AIFace.new" "$APP/Contents/MacOS/AIFace"
# Translations (Localizable.strings per language): the app follows the Mac's language.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"
cp -R app/macos/Resources/*.lproj "$APP/Contents/Resources/"
# App icon: AppIcon.png (1024, tools/make_icon.py) -> AppIcon.icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s app/macos/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null 2>&1
  sips -z $((s * 2)) $((s * 2)) app/macos/Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null 2>&1
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" >>"$LOG" 2>&1
rm -rf "$(dirname "$ICONSET")"

msg "3/4 앱 정보와 서명" "3/4 App info and signing"
# NSAllowsLocalNetworking: the menu bar face reads http://127.0.0.1 (the Python controller).
cat > "$APP/Contents/Info.plist" <<'PLIST'
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
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >>"$LOG" 2>&1

msg "4/4 앱 실행" "4/4 Starting the app"
echo "Built $(date)" >>"$LOG"
touch "$APP"   # Finder and System Settings pick up the new icon
open "$APP"
echo
msg "완료: 메뉴바 오른쪽 위의 얼굴을 누르면 메뉴가, 설정…을 누르면 설정 창이 열려요." \
    "Done: click the face at the top right of the menu bar for the menu; Settings… opens the settings."
sleep 2
# Close the Terminal window that double-clicking the .command file opened (Terminal keeps it
# open by default). Only on success: a failed build leaves its log on screen. The closer is
# detached from the window (new session) and waits until this script has ended, so Terminal
# has nothing running in the window and closes it without asking.
if [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
  CLOSER=$(cat <<'PY'
import os, subprocess, time
if os.fork():
    os._exit(0)
os.setsid()
for fd in (0, 1, 2):
    os.dup2(os.open(os.devnull, os.O_RDWR), fd)
time.sleep(1.5)
subprocess.run(['osascript', '-e', 'tell application "Terminal" to close '
                '(every window whose name contains "Build AI Face.command")'])
PY
)
  /usr/bin/python3 -c "$CLOSER" </dev/null >/dev/null 2>&1
fi
