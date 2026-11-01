# AI Face

**A little face for your AI.** AI Face is a free, open-source macOS menu bar app. While you chat with Claude or Codex, the AI can choose an animated expression for each reply through a local MCP connection. An optional ESP32 round LCD can show the same face on your desk.

[Download from GitHub Releases](https://github.com/jason401/ai-face/releases) · [Installation guide](docs/INSTALL_RELEASE.md) · [MIT License](LICENSE)

![78 expression previews rendered from the firmware](docs/faces-en.png)

## Features

- 78 animated expressions in 11 groups, from happy and thinking to curious, sleepy and facepalm.
- Claude-orange / GPT-green / manual-white rings; monochrome menu bar mode uses patterns instead.
- Manual expression picker, timer, clock, photo/slideshow and campfire screen savers.
- Local expression history and statistics; conversation text is not saved in that history.
- Optional, separately controlled Calendar access and read-only Mail access for connected AIs.
- Optional timed keep-awake support, with time, temperature, battery and app-exit safeguards.
- Optional Seeed XIAO ESP32S3 + GC9A01 240×240 round LCD; firmware source included.
- English and Korean interface, following your Mac's language.

## Download and install

1. Open the official [Releases page](https://github.com/jason401/ai-face/releases). Download **AI-Face-2.1.0-macOS-universal.zip** and **SHA256SUMS.txt** from the published release. If no release is listed yet, a ready-to-run download is not yet available; GitHub's source ZIP is not an installer.
2. Requires **macOS 13+** and **Xcode Command Line Tools**, which supply the external `/usr/bin/python3` runtime. If missing, run `xcode-select --install` and complete Apple's installation. A paid Apple Developer membership is not required.
3. Compare `shasum -a 256 <downloaded-zip>` with the release checksum, extract the ZIP, and move **AI Face.app** into **Applications**. The app is Universal 2 (Apple silicon + Intel); architecture inclusion is verified during packaging, but execution on every hardware/OS combination is not guaranteed.
4. Open AI Face. In **Settings → AI**, connect Claude desktop, Codex and/or Claude Code, then fully quit and reopen that AI app. The conversation must expose the registered local MCP tools; this does not connect mobile/web chats or all chat modes automatically.

No hardware, signing private key or source checkout is required to run the downloaded app. The face changes while AI Face is running. Full instructions and uninstall steps: [Installation guide](docs/INSTALL_RELEASE.md).

### macOS security warning

The app uses a local signature, **not Apple Developer ID signing or notarization**. Apple has not verified this release. After verifying the official source and checksum, try opening the app once. If blocked as an unidentified developer, use **System Settings → Privacy & Security → Open Anyway** for this specific trusted app and confirm. [Apple's guidance](https://support.apple.com/en-us/102445).

Do not disable Gatekeeper globally, remove quarantine recursively, or bypass malware/computer-damage warnings. Stop if the checksum does not match. An individual Gatekeeper exception does not install a missing Python runtime.

### Updates

Downloaded-app users should get new versions from [GitHub Releases](https://github.com/jason401/ai-face/releases), quit AI Face and replace the app in Applications. Settings and history remain in your local Application Support folder.

The current in-app updater checks the `stable` source branch at startup and every three hours. It builds an update only after you click Update now, and requires an existing local signing identity, Python and Command Line Tools. It is for existing source-build installations, **not a release-ZIP updater**. Other users can turn off source update checks and use manual release downloads.

### Optional LCD

Use Seeed XIAO ESP32S3 and a GC9A01 round SPI LCD. Pins are documented in `firmware/ESP32_Display/ESP32_Display.ino`. Firmware compilation needs the ESP32 Arduino core, Adafruit GFX and Adafruit GC9A01A libraries. **Settings → Board → Update firmware** compiles and uploads only when requested. No precompiled firmware is included in the desktop download.

## Privacy

- Settings, photos and expression history are stored locally in `~/Library/Application Support/AI Face/`, outside this source repository.
- Calendar and Mail access are optional and controlled per AI. Tool results sent to an AI become part of that provider's conversation; local app storage does not mean the AI provider processes everything locally.
- The app listens on `127.0.0.1`, not a public network interface. Mutations and Calendar/Mail reads require a runtime token. Some local read routes, including photo and expression-history reads, are not token-protected: other programs on the same Mac may read them. Do not expose this server through a public tunnel.
- GitHub updates/downloads require network access. Connecting an AI adds its MCP registration; it does not publish local account credentials or user data.

## Development

The Swift app uses system frameworks; Python runtime code uses the standard library. Build prerequisites include an existing **AI Face Local Signing** identity in the developer's keychain. Never share its private key. The build stops if that identity is absent; there is no ad-hoc fallback.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
bash tools/firmware_sim/run.sh
zsh tools/build_app.sh --stage       # stage only; installed app is untouched
zsh tools/package_release.sh        # stage a Universal 2 release ZIP and checksums
```

A normal source build installs only when `/Applications/AI Face.app` is absent. The app's source updater uses a separate checkout; it never modifies this developer folder. See [release maintenance](docs/RELEASING.md) for packaging and verification.

## AI-assisted development

Developed with assistance from Claude and ChatGPT/Codex for implementation, debugging, tests and documentation. AI assistance is not an independent security audit, a guarantee of correctness, or an endorsement by those companies.

## License

Copyright © 2026 jason401. Project-owned material is available under the [MIT License](LICENSE), permitting use, modification and redistribution, including commercial use, with its required notices. External dependencies retain their own licenses; see [Third-party notices](THIRD_PARTY_NOTICES.md). Product names are trademarks of their owners; this is an unofficial project.

---

## 한국어

AI와 대화할 때마다 표정을 보여 주는 무료 오픈소스 맥 메뉴바 앱입니다. 78가지 움직이는 표정, 타이머, 사진·시계·모닥불 대기 화면, 표정 기록을 지원합니다. ESP32 원형 LCD는 선택 사항입니다.

### 설치

1. 공식 [GitHub Releases](https://github.com/jason401/ai-face/releases)에서 Universal ZIP과 체크섬을 받으세요. 소스 코드 ZIP은 설치 프로그램이 아닙니다.
2. macOS 13 이상과 무료 Xcode 명령줄 도구가 필요합니다. 없다면 `xcode-select --install`로 설치하세요. 유료 개발자 계정이나 제작자의 서명 키는 필요하지 않습니다.
3. 체크섬을 확인하고 압축을 푼 뒤 **AI Face.app**을 **응용 프로그램**으로 옮기세요.
4. Apple 공증이 없어 차단되면 공식 파일인지 확인한 뒤 **시스템 설정 → 개인정보 보호 및 보안 → 확인 없이 열기**로 개별 허용하세요. 악성코드·컴퓨터 손상 경고는 우회하지 마세요.
5. 앱 설정 → AI에서 사용할 AI 앱을 연결하고, 그 AI 앱을 완전히 종료했다가 다시 실행하세요. 대화에서 로컬 MCP 도구를 사용할 수 있어야 합니다.

다운로드 사용자는 이후 버전도 Releases에서 받아 앱을 종료한 뒤 교체하세요. 앱 안의 업데이트는 기존 로컬 서명 환경을 사용하는 소스 빌드 방식입니다. [자세한 설치·업데이트·삭제 안내](docs/INSTALL_RELEASE.md)

사진과 설정은 맥에 저장되지만, AI 도구로 읽은 결과는 AI 서비스에 전달될 수 있습니다. 캘린더·메일 접근은 필요한 경우에만 허용하세요.

Claude와 ChatGPT/Codex의 도움을 받아 개발한 AI-assisted development 프로젝트입니다. 프로젝트 소유 자료는 [MIT License](LICENSE)이며 외부 구성요소는 각자의 라이선스를 따릅니다.
