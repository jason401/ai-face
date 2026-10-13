# AI Face — notes for Claude

Younghun's macOS menu bar face. AIs (Claude, Codex/GPT) set its expression through a local MCP
server named `ai-face`. The ESP32 round LCD board is optional. Public repo: github.com/jason401/ai-face (MIT).

## How to work with Younghun
- Answer in Korean, simply. Avoid jargon; when a technical word is needed, say what it does in plain words.
- Every reply: call the `ai-face` MCP tool `set_expression` with a mood that fits YOUR reply (vary it).
  If the tool is not available, skip silently.
- "아직 코드 수정하지마" / "수정하지 말고" → discuss only, do not edit files.
- When he asks for something to be automatic, he means zero manual steps for him.
- Only make changes that are clear, safe and certain; say plainly what is unverified.
- Commit and push to `origin main` when a change is done and tests pass. End commit messages with
  `Co-Authored-By: Claude <noreply@anthropic.com>`. Remove `__pycache__` before `git add`.

## Layout
- `app/macos/*.swift` — the menu bar app (face drawing, settings window, calendar via EventKit).
  `main.swift` handles `AIFace --calendar ...` (JSON CLI) before the app starts.
  Strings: `app/macos/Resources/{en,ko}.lproj/Localizable.strings` (`L("...")`; add Korean for new labels).
- `core/run_server.py` → `core/aiface/server.py` — local HTTP server the app starts (127.0.0.1,
  token header `X-ESP-Token`). Board serial, history, photos, keep awake, calendar.
- `core/ai_face_mcp.py` — thin MCP shim; copied to `~/Library/Application Support/AI Face` and
  forwards to the app. Tool list is gated by settings (calendar per-AI read/write).
- `core/ai_face_awake.py` — keep-awake helper (`hook on|off` for Claude Code hooks, `run CMD`, `status`).
- `core/aiface/integrations.py` — connects Claude desktop, Codex, Claude Code (`claude mcp add -s user`)
  and the Claude Code keep-awake hooks (`~/.claude/settings.json`).
- `core/aiface/moods.py` — 78 moods in 11 groups (the MCP enum comes from here).
- `firmware/` — ESP32 firmware; `tools/firmware_sim` checks it on the computer.
- Data: `~/Library/Application Support/AI Face` (settings.json, history, photos, awake.json, calendar log).
- Docs: `README.md`, `docs/사용방법.md` (user guide, Korean), `docs/감정표현-설계.md`. Update them with features.

## Build and test
- Tests: `python3 -m unittest discover -s tests` and `bash tools/firmware_sim/run.sh`. Run both before committing.
- App: `zsh tools/build_app.sh < /dev/null` (same as double-clicking `Build AI Face.command`; it quits,
  rebuilds and restarts the app; log in `app-build.log`). Compiled with `xcrun swiftc`
  (Cocoa, SwiftUI, ServiceManagement, EventKit) — no Xcode project, so no SwiftUI macros like `#Preview`.
- Signing: self-signed identity "AI Face Local Signing" (keeps the calendar permission across builds);
  falls back to ad-hoc.

## Rules that must stay true (agreed with Younghun)
- Never ask for, store or handle his password. sudo is only ever `sudo -n` (keep awake uses a sudoers
  rule installed by `tools/Set up Keep Awake.command`).
- Calendar: per-AI read/write switches live in the app (Codex/GPT off by default). Notes/attendees off by
  default; links and passcodes in locations are hidden. AI may change or delete only events added through
  AI Face (tagged in notes). "Ask me before every change" is on by default; every change can be undone.
  Repeating events are not changed.
- Keep awake always has a time limit and a failsafe that turns it off if the app dies; it turns off on
  overheating and Low Power Mode.
- Mail access is deferred ("찝찝해서" — do not start it without asking).

## Open items (ask before starting)
- Does the Mac sleep right away when keep awake ends with the lid closed? (maybe `pmset sleepnow`)
- Fully automatic keep awake; Claude Code hook event names not double-checked against docs.
- Settings → AI apps → Claude Code: if it shows "Not installed" when only the Claude app's Code tab is
  used (no `claude` command on PATH), register by another way.
- Later ideas: mail reading, more moods, AI-to-AI chat, token gauge, flashing the board at home.
- Test calendar event "☕ AI Face 캘린더 쓰기 테스트" (10/13 09:00) — delete when he asks.
