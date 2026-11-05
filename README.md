# AI Face

**A little face for your AI.** AI Face is a free, open-source macOS menu bar app. While you chat with Claude or Codex, the AI can choose an animated expression for each reply through a local MCP connection. An optional ESP32 round LCD can show the same face on your desk.

[Download from GitHub Releases](https://github.com/jason401/ai-face/releases) · [Installation guide](docs/INSTALL_RELEASE.md) · [User guide](docs/USER_GUIDE.md) · [MIT License](LICENSE)

![78 expression previews rendered from the firmware](docs/faces-en.png)

## Features

- 78 animated expressions in 11 groups, from happy and thinking to curious, sleepy and facepalm.
- Claude-orange / GPT-green / manual-white rings; monochrome menu bar mode uses patterns instead.
- Manual expression picker, timer, clock, photo/slideshow and campfire screen savers.
- Local expression history and statistics; conversation text is not saved in that history.
- Optional, separately controlled Calendar access and read-only Mail access for connected AIs.
- Optional read-only shared folders: pick folders once, then any connected chat on this Mac can list, search and read them (PDF, Word, PowerPoint and text).
- Optional timed keep-awake support, with time, temperature, battery and app-exit safeguards.
- Optional Seeed XIAO ESP32S3 + GC9A01 240×240 round LCD; firmware source included.
- English and Korean interface, following your Mac's language.

## Download and install

1. Open the official [Releases page](https://github.com/jason401/ai-face/releases). Download **AI-Face-2.1.0-macOS-universal.zip**. This is the only download needed to install the app; **SHA256SUMS.txt** is optional and is used only to check file integrity. If no release is listed yet, a ready-to-run download is not yet available; GitHub's source ZIP is not an installer.
2. Requires **macOS 13+** and **Xcode Command Line Tools**, which supply the external `/usr/bin/python3` runtime. If missing, run `xcode-select --install` and complete Apple's installation. A paid Apple Developer membership is not required.
3. Extract the ZIP and move **AI Face.app** into **Applications**. The app is Universal 2 (Apple silicon + Intel); architecture inclusion is verified during packaging, but execution on every hardware/OS combination is not guaranteed.
4. Open AI Face. In **Settings → AI**, connect Claude desktop, Codex and/or Claude Code, then fully quit and reopen that AI app. The conversation must expose the registered local MCP tools; this does not connect mobile/web chats or all chat modes automatically.

No hardware, signing private key or source checkout is required to run the downloaded app. The face changes while AI Face is running. Full instructions and uninstall steps: [Installation guide](docs/INSTALL_RELEASE.md).

Optional integrity check: download `SHA256SUMS.txt` and compare it with `shasum -a 256 <downloaded-zip>`. This is not required for installation and does not certify that an app is safe.

### macOS security warning

The app uses a local signature, **not Apple Developer ID signing or notarization**. Apple has not verified this release. After confirming the download came from the official release page, try opening the app once. If blocked as an unidentified developer, use **System Settings → Privacy & Security → Open Anyway** for this specific trusted app and confirm. [Apple's guidance](https://support.apple.com/en-us/102445).

Do not disable Gatekeeper globally, remove quarantine recursively, or bypass malware/computer-damage warnings. Stop if the checksum does not match. An individual Gatekeeper exception does not install a missing Python runtime.

### Updates

Downloaded-app users should get new versions from [GitHub Releases](https://github.com/jason401/ai-face/releases), quit AI Face and replace the app in Applications. Settings and history remain in your local Application Support folder.

The current in-app updater checks the `stable` source branch at startup and every three hours. It builds an update only after you click Update now, and requires an existing local signing identity, Python and Command Line Tools. It is for existing source-build installations, **not a release-ZIP updater**. Other users can turn off source update checks and use manual release downloads.

### Optional LCD

Use Seeed XIAO ESP32S3 and a GC9A01 round SPI LCD (optionally with a CST816 touch chip for swiping between face, campfire and clock). Pins are documented in `firmware/ESP32_Display/ESP32_Display.ino`. Firmware compilation needs the ESP32 Arduino core, Adafruit GFX and Adafruit GC9A01A libraries. **Settings → Display → Board → Details… → Update firmware** compiles and uploads only when requested. No precompiled firmware is included in the desktop download.

## Privacy

- Settings, photos and expression history are stored locally in `~/Library/Application Support/AI Face/`, outside this source repository.
- Calendar, Mail and shared-folder access are optional and controlled per AI. Tool results sent to an AI become part of that provider's conversation; local app storage does not mean the AI provider processes everything locally.
- The app listens on `127.0.0.1`, not a public network interface. Mutations and Calendar/Mail/shared-folder reads require a runtime token. Some local read routes, including photo and expression-history reads, are not token-protected: other programs on the same Mac may read them. Do not expose this server through a public tunnel.
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

## Weather-aware campfire

The campfire can reflect local clear/partly cloudy/overcast/rain/snow/fog conditions, daylight and wind while keeping its original pixel-art fire. Display → Campfire weather lets you choose a city, use automatic current weather, or preview a selected date and city-local hour. Future dates are limited to the available forecast horizon (up to 15 days ahead); older dates use historical reanalysis. The Apply button opens the campfire. Return to Automatic for current conditions.

The Mac retrieves weather every 15 minutes and sends compact parameters to the board. Current conditions are model estimates, not direct local observations. A matching board firmware update is needed; older firmware remains usable with the original fire. Network/data failure retains the last valid selection for up to two hours, then restores the original scene. City selection is stored locally; the coordinates are sent to the weather service. No precise location permission, API key, microphone or camera is needed.

Weather data: [Open-Meteo](https://open-meteo.com/), [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). City search uses Open-Meteo's [GeoNames-based geocoding](https://open-meteo.com/en/docs/geocoding-api). The free endpoint is for non-commercial use; commercial distribution requires reviewing the provider's terms.

![Actual firmware weather previews](docs/images/campfire-weather.png)
