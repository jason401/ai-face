# AI Face — notes for Claude

Read `HANDOFF.md` and `AGENTS.md` first. The installed app and stable update checkout are independent of this developer folder. The current build stages a complete signed bundle; old instructions about sibling runtime code and ad-hoc fallback below are superseded.

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
- Pushing uses the GitHub CLI login, once per Mac: `gh auth login --web --git-protocol https` then
  `gh auth setup-git` (install gh with Homebrew; he only clicks Authorize). If push asks for a username,
  offer exactly this — never tokens or GitHub Desktop.

## Layout
- `app/macos/*.swift` — the menu bar app (face drawing, settings window, calendar via EventKit).
  `main.swift` handles `AIFace --calendar ...` (JSON CLI) before the app starts.
  `Mail.swift` reads Mail (`AIFace --mail ...`).
  Strings: `app/macos/Resources/{en,ko}.lproj/Localizable.strings` (`L("...")`; add Korean for new labels).
- Settings window: compact cards like AI Illuminati (`SettingsKit.swift`: SettingsPage/Card/Row/Note/Action).
  Four tabs in `SettingsTabs.swift` (General · AI · Board · History), window 334×460 pt. Check looks with
  `zsh tools/tests/render_settings.sh <dir>` (PNG previews, en/ko, light/dark; no real app or data touched).
- `core/run_server.py` → `core/aiface/server.py` — local HTTP server the app starts (127.0.0.1,
  token header `X-ESP-Token`). Board serial, history, photos, keep awake, calendar.
- `core/ai_face_mcp.py` — thin MCP shim; copied to `~/Library/Application Support/AI Face` and
  forwards to the app. Tool list is gated by settings (calendar per-AI read/write).
- `core/ai_face_awake.py` — keep-awake helper (`hook on|off` for Claude Code hooks, `run CMD`, `status`).
- `core/aiface/integrations.py` — connects Claude desktop, Codex, Claude Code (`claude mcp add-json -s user`;
  falls back to the copy inside Claude.app's Code tab under `~/Library/Application Support/Claude/claude-code`)
  and the Claude Code keep-awake hooks (`~/.claude/settings.json`).
- `core/aiface/updater.py` — automatic updates: at start and every 3 h fetches `origin stable` into its private
  checkout (`Application Support/AI Face/source`), tests, `build_app.sh --stage`, then the transactional
  installer swaps `/Applications/AI Face.app`. Never installs a version older than the running one.
  Waits while busy. State in `update.json`.
- `core/aiface/moods.py` — 78 moods in 11 groups (the MCP enum comes from here).
- `firmware/` — ESP32 firmware; `tools/firmware_sim` checks it on the computer.
- Data: `~/Library/Application Support/AI Face` (settings.json, history, photos, awake.json, calendar log).
- Docs: `README.md`, `docs/사용방법.md` (user guide, Korean), `docs/감정표현-설계.md`. Update them with features.

## Build and test
- Tests: `python3 -m unittest discover -s tests` and `bash tools/firmware_sim/run.sh`. Run both before committing.
- App (same rule as AI Illuminati): the installed app changes only through stable updates. Check a build with
  `zsh tools/build_app.sh --stage < /dev/null` (stages `AI Face.update.app`, touches nothing; log in
  `app-build.log`). To ship: tests pass → push `main` → `git push origin main:stable` (fast-forward only, never
  partial work) → Settings → General → Check now (or wait for the 3-hourly check). A plain build installs
  only on a Mac without `/Applications/AI Face.app`. Compiled with `xcrun swiftc`
  (Cocoa, SwiftUI, ServiceManagement, EventKit) — no Xcode project, so no SwiftUI macros like `#Preview`.
- Signing: preserve the existing "AI Face Local Signing" identity; signing failure stops installation. No ad-hoc fallback.

## Rules that must stay true (agreed with Younghun)
- Never ask for, store or handle his password. sudo is only ever `sudo -n` (keep awake uses a sudoers
  rule installed by `tools/Set up Keep Awake.command`).
- Calendar: per-AI read/write switches live in the app (Codex/GPT off by default). Notes/attendees off by
  default; links and passcodes in locations are hidden. AI may change or delete only events added through
  AI Face (tagged in notes). "Ask me before every change" is on by default; every change can be undone.
  Repeating events are not changed.
- Keep awake always has a time limit and a failsafe that turns it off if the app dies; it turns off on
  overheating and Low Power Mode.
- Mail: read only (inboxes, via Apple events from `AIFace --mail`). Never add sending, moving, deleting or
  marking read. Per-AI switches (GPT off by default); links and codes hidden by default.

## Open items (ask before starting)
- Does the Mac sleep right away when keep awake ends with the lid closed? (maybe `pmset sleepnow`)
- Fully automatic keep awake; Claude Code hook event names not double-checked against docs.
- Later ideas: more moods, AI-to-AI chat, token gauge.
- Menu bar item is a bit wider than its neighbors (squareLength + 2 pt inset for the bounce/shake).
  Discussed 2026-10-24: leave it for now; maybe variableLength later.
- Discussed 2026-10-19, not started (he has his own similar ideas to add): meeting alert 10 min before
  (ring counts down), face reacts to mail from important senders, morning greeting by the day's load,
  face showing Claude Code task state. Plan: a watcher thread in the app's server (not MCP: MCP only
  runs when an AI calls it). Order 1 meeting, 2 morning, 3 mail. Mail is heavy (9-18 s per full read):
  poll only the unread count (speed not measured yet), only while Mail is already open; important-sender
  list, quiet hours, priority vs AI faces / timer / saver, drop missed alerts after sleep.
- Test calendar event "☕ AI Face 캘린더 쓰기 테스트" (10/13 09:00) — delete when he asks.
