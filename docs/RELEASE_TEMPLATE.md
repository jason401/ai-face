# AI Face <version>

Maintainer template — replace every placeholder and remove this line before publication. Do not publish until the checks in RELEASING.md pass.

Free, open-source macOS menu bar face for AI conversations. Optional ESP32 round LCD support.

## Downloads

- Supported macOS: <tested minimum and versions>
- Architecture: <arm64 and/or x86_64 actually tested>
- Source commit / tag: <full SHA / tag>
- Source installation ZIP: <AI-Face-X.Y.Z-source.zip link>
- Checksums: <uploaded SHA256SUMS.txt link>
- External prerequisites: macOS 13+, Xcode Command Line Tools (Swift, Git, /usr/bin/python3), internet
- Signing / notarization: built and signed on each user's Mac with its own local identity; not Apple notarized

## Install

1. Download the source ZIP (the only download needed; SHA256SUMS.txt is an optional integrity check) and extract it.
2. Double-click **Install AI Face.command**. It downloads this tag from GitHub, creates or reuses this Mac's AI Face Local Signing identity, builds AI Face and puts it in Applications. Approve macOS prompts yourself; it never asks for a password.
3. If macOS blocks the file and you trust this official download, use System Settings → Privacy & Security → Open Anyway. Do not disable Gatekeeper. [Apple guidance](https://support.apple.com/en-us/102445).
4. Connect your AI app in Settings → AI. Later versions arrive in the app: Update now.

An app from an earlier ready-made download is moved to the Trash and replaced; settings and history stay.

## Changes and known limitations

<User-visible changes, fresh-install and upgrade test results, required permissions and remaining limitations. State whether this is a source-only release if no verified app archive is attached.>

## License and development

Copyright © 2026 jason401. Project-owned material is MIT licensed; bundled third-party components retain their own licenses. Include LICENSE and THIRD_PARTY_NOTICES.md with the downloads.

Developed with assistance from Claude and ChatGPT/Codex. AI assistance is not a security guarantee or an endorsement by those providers.
