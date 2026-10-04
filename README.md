# AI Face

**A little face for your AI.** While you chat with Claude or ChatGPT/Codex, the AI picks a facial expression for each reply and it shows up as an animated round face in the macOS menu bar, and, if you build one, on a small round LCD on your desk.

[한국어 설명은 아래에 있어요.](#한국어)

- 71 animated moods (happy, thinking, awkward, cheering, idea, ...), chosen by the AI through a local MCP server
- The ring around the face shows who chose it: Claude (orange), GPT (green) or you (white). In monochrome mode the ring pattern shows it instead
- Screen savers: sleepy → asleep, clock, photo, slideshow, pixel-art campfire
- Countdown timer ring ("start a 25-minute pomodoro"), photo library, expression history and daily stats
- Optional hardware: Seeed XIAO ESP32S3 + 1.28" GC9A01 240×240 round LCD, firmware included, 3D-printable case in `hardware/housing`

## Install (macOS 13+)

1. Install the Xcode Command Line Tools if you do not have them: `xcode-select --install`
2. Get the code: `git clone https://github.com/jason401/ai-face.git` (or download the ZIP).
3. Double-click **`앱 빌드.command`** ("build app"). It compiles `AI Face.app` in the folder and starts it: a face appears in the menu bar and the settings window opens. The app is built on your own Mac, so it opens without a Gatekeeper warning. (If you downloaded the ZIP, macOS may block the `.command` file the first time: right-click it → Open, or allow it in System Settings → Privacy & Security.)
4. In **Settings → AI 연결 (AI apps)**, click **연결 (Connect)** next to Claude desktop and/or Codex, then quit (⌘Q) and reopen those apps.

For Claude Code, use **등록 명령 복사 (Copy command)** in the same tab and paste it into a terminal.

### The round LCD (optional)

- Board: Seeed XIAO ESP32S3; display: GC9A01 240×240 round SPI LCD (pins in `firmware/ESP32_Display/ESP32_Display.ino`).
- Install Arduino IDE 2 with the ESP32 board package once. After that, **Settings → 보드 (Board) → 펌웨어 업데이트 (Update firmware)** compiles and uploads the firmware without opening the IDE.
- Plug the board in and the app connects to it by itself.

## How it works

```
Claude / Codex ──MCP (stdio)──▶ core/aiface/mcp_server.py ──HTTP (127.0.0.1)──▶ AI Face.app
                                                                                 ├─ menu bar face
                                                                                 └─ USB serial ─▶ ESP32 LCD
```

```
app/macos/*.swift       menu bar app (Swift): starts the server, menu bar face and menu, SwiftUI settings
core/aiface/            Python core (standard library only)
  server.py             local server (127.0.0.1, random port + token), connects the board automatically
  mcp_server.py         MCP stdio server: set_expression, get_expression, start_timer, show_photo, ...
  integrations.py       registers the MCP server with Claude desktop / Codex
  board.py              ESP32 over USB serial (protocol FACE8)
  moods.py              the 71 mood animations (+ auto), settings
  history.py            expression log and stats (moods only, never conversation text)
  library.py            photo library
  flasher.py            compile + upload the firmware with Arduino IDE's arduino-cli
firmware/ESP32_Display/ ESP32 firmware
hardware/housing/       3D-printable case
tools/                  app build script, CLI installer, firmware simulator
tests/                  tests
```

User data lives in `~/Library/Application Support/ESP32Face/` (settings, photos, history).

## Development

```
python3 -m unittest discover -s tests     # Python tests + firmware simulator
bash tools/firmware_sim/run.sh            # firmware simulator only (needs a C++ compiler)
```

- After changing code, run `앱 빌드.command` again. The app also refreshes the installed MCP server code when it starts.
- The app is built with `xcrun swiftc -swift-version 5` (no Xcode project). Do not use SwiftUI macros such as `@State`: the Command Line Tools do not ship the macro plugin.
- In the firmware, every struct used in a function signature must be declared above the `RingColorFn` typedef (where the Arduino builder inserts prototypes). The simulator follows the same rule.

## License

[MIT](LICENSE). Claude and ChatGPT are trademarks of their owners; this is an unofficial hobby project.

---

## 한국어

Claude나 GPT와 대화하면 AI가 대답마다 표정을 골라서 **맥 메뉴바의 동그란 얼굴**에 보여줘요. ESP32와 원형 LCD로 실물 얼굴도 만들 수 있어요(선택).

- 71가지 표정, 누가 골랐는지 테두리 색(Claude 주황 / GPT 초록 / 직접 흰색), 흑백 모드에서는 테두리 무늬로 구분
- 대기 화면: 졸림→잠, 시계, 사진, 슬라이드쇼, 픽셀 모닥불
- 타이머 링, 사진 보관함, 표정 기록과 하루 통계, 보드 펌웨어 업데이트(Arduino IDE 창 없이)

### 설치

1. `앱 빌드.command` 더블클릭 → `AI Face.app`이 만들어지고 실행돼요(메뉴바 얼굴, 설정 창).
2. 설정 → **AI 연결**에서 Claude 데스크톱 / Codex **연결**
3. Claude(와 Codex)를 ⌘Q로 껐다가 다시 실행

자세한 사용법은 [docs/사용방법.md](docs/사용방법.md)에 있어요.
