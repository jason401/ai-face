# Install AI Face

Free, open-source software under the MIT License. The desktop app works without an ESP32.

## Requirements

- macOS 13 or later, Apple silicon or Intel (Universal 2 app).
- Xcode Command Line Tools, which supply the `/usr/bin/python3` runtime used by this release. If needed, run `xcode-select --install` in Terminal and finish Apple's installation before opening AI Face. You do not need Xcode itself or a paid Apple Developer membership.
- Claude desktop, Codex or Claude Code for AI-controlled expressions. Manual expressions work without an AI connection.

## Installation

1. Download the app ZIP and `SHA256SUMS.txt` from [the official release page](https://github.com/jason401/ai-face/releases). Verify the downloaded ZIP with `shasum -a 256 <filename>` against the published checksum.
2. Extract the ZIP. Move **AI Face.app** from the extracted **AI Face** folder into **Applications**. Keep the license and notices for your records.
3. Open AI Face. It is locally signed, not Apple Developer ID signed or notarized. If a trusted download is blocked as an unidentified developer, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway** and confirm. Do not disable Gatekeeper globally or bypass a malware / computer-damage warning. [Apple's guidance](https://support.apple.com/en-us/102445).
4. A face appears in the menu bar. In **Settings → AI**, connect your AI app, quit that AI app completely and reopen it. The conversation must support the registered local MCP tools.

You do not need the maintainer's signing identity, private key, source checkout or Arduino toolchain to run this app. Calendar, Mail, login launch, keep-awake setup and the ESP32 are optional; enable only what you want. Installing the app does not flash firmware or enable those permissions for you.

## Updates

For downloaded-app installations, use the same official Releases page for updates. Quit AI Face before replacing its app in Applications. Your settings and history stay in `~/Library/Application Support/AI Face/`.

The current in-app updater checks the `stable` source branch and compiles locally; it is intended for existing source-build installations with a local signing identity. It does not download release ZIPs. Use manual release downloads on other Macs, and turn off automatic source update checks in Settings → General if you do not need them. A public binary updater is not included in this release.

## Uninstall

Disconnect integrations in Settings → AI and turn off Open at login. Remove the optional keep-awake rule in its settings if you installed it. Quit the app, delete it from Applications, and optionally delete `~/Library/Application Support/AI Face/` to remove its local data.
