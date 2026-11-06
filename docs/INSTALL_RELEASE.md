# Install AI Face

Free, open-source software under the MIT License. The desktop app works without an ESP32.

## Requirements

- macOS 13 or later, Apple silicon or Intel.
- Xcode Command Line Tools: the Swift compiler, Git and the `/usr/bin/python3` runtime. If needed, run `xcode-select --install` in Terminal and finish Apple's installation. You do not need Xcode itself or a paid Apple Developer membership.
- An internet connection (the installer downloads the official source from GitHub).
- Claude desktop, Codex, Claude Code or AI Illuminati for AI-controlled expressions. Manual expressions work without an AI connection.

## Installation

The release is a **source installation package**: AI Face is built on your Mac and signed with your Mac's own local signing identity. That is what lets the app update itself later.

1. Download `AI-Face-<version>-source.zip` from [the official release page](https://github.com/jason401/ai-face/releases). **Only the ZIP is needed.** `SHA256SUMS.txt` is an optional integrity check.
2. Extract it and double-click **`Install AI Face.command`**. If macOS blocks it as from an unidentified developer, and you trust the download, use **System Settings → Privacy & Security → Open Anyway** for this file. Do not disable Gatekeeper globally or bypass a malware warning. [Apple's guidance](https://support.apple.com/en-us/102445).
3. The installer, in a Terminal window:
   - downloads the official release tag into `~/Library/Caches/AI Face/install.*/source`;
   - creates the **AI Face Local Signing** identity in your login keychain, or reuses an existing one. macOS may ask you to confirm in its own window; the script never asks for or stores a password;
   - prepares the app's private update folder (`~/Library/Application Support/AI Face/source`, following the `stable` branch);
   - builds the app and puts it in **Applications**, then opens it.
4. A face appears in the menu bar. In **Settings → AI**, connect your AI app. Quit and reopen Claude desktop or Codex after connecting. Claude Code applies to new sessions; AI Illuminati picks it up within 30 seconds.

**An earlier ready-made download (2.1.0)** was signed on the maintainer's Mac and cannot update itself on yours. The installer quits it, moves it to the Trash and installs your own build. Settings, history and photos stay. macOS may ask again for Calendar or Mail access, because the app's signature changed. If AI Face is already built and signed on this Mac, the installer leaves it alone.

The signing identity is a private key on your Mac. Never share it or upload it. A local signature is not Apple Developer ID signing or notarization; Apple has not verified this software.

## Optional integrity check

Compare `shasum -a 256 <filename>` with the value in `SHA256SUMS.txt`. This is optional and is not a malware or safety certification.

## Updates

The app checks the public `stable` branch at startup and every three hours (switch in Settings → General). When there is a new version it shows **Update now** in Settings and the menu; nothing is installed until you click it. It then runs the tests, builds with your signing identity and replaces the app safely (the previous app is kept until the new one works). Settings and history stay in `~/Library/Application Support/AI Face/`.

## Uninstall

Disconnect integrations in Settings → AI and turn off Open at login. Remove the optional keep-awake rule in its settings if you installed it. Quit the app and delete it from Applications. Optionally delete `~/Library/Application Support/AI Face/` (settings, history, photos, update folder) and `~/Library/Caches/AI Face/`. The **AI Face Local Signing** identity can be deleted in Keychain Access if you no longer build AI Face.
