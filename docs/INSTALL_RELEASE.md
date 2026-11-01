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

## 한국어

macOS 13 이상, Apple silicon·Intel을 지원합니다. 무료 Xcode 명령줄 도구가 필요하며, 없다면 터미널에서 `xcode-select --install`을 실행하고 설치를 완료하세요. 유료 개발자 계정이나 제작자 서명 키는 필요하지 않습니다.

공식 Releases의 ZIP과 체크섬을 받아 확인하고, 압축을 푼 폴더 안의 **AI Face.app**을 **응용 프로그램**으로 옮기세요. Apple 공증이 없어서 차단되면 신뢰하는 공식 파일인지 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**로 개별 허용하세요. 악성코드 경고는 우회하지 마세요.

앱 설정 → AI에서 사용할 앱을 연결하고 그 AI 앱을 완전히 껐다 켜세요. 일반 다운로드 사용자는 이후 버전도 Releases에서 받아 앱을 종료한 뒤 교체하면 됩니다. 현재 앱 안의 업데이트 기능은 개발자용 소스 빌드 방식이므로, 다른 Mac에서는 Releases를 통한 수동 업데이트를 사용하세요.
