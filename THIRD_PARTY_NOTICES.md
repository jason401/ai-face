# Third-party components and asset provenance

Reviewed 2026-10-31. The project's MIT license covers material the project owns; it does not replace any third-party license. No vendored third-party library implementation or font file was found in the tracked tree. This inventory describes referenced dependencies, not a complete bill of materials for a future compiled distribution.

## Desktop app and development tools

| Component | Use | License / source |
| --- | --- | --- |
| Python 3 | External runtime; app code uses the standard library | [PSF license and bundled notices](https://docs.python.org/3/license.html) |
| Apple Cocoa, SwiftUI, ServiceManagement, EventKit | macOS system frameworks; not copied into this repository | Apple platform / SDK terms; not relicensed under MIT |
| Pillow | Optional icon and face-preview generation | [MIT-CMU](https://github.com/python-pillow/Pillow/blob/main/LICENSE) |

Python, SDKs and Pillow are not bundled library distributions in this source tree. If a later installer embeds a runtime or its dependencies, retain the notices for the exact versions and their transitive dependencies. The current app uses externally installed Python.

## Fonts and images

- `tools/make_icon.py` procedurally draws `app/macos/Resources/AppIcon.png`; no downloaded icon or photo input is referenced.
- `tools/make_preview.py` renders the project firmware into `docs/faces-en.png` and `docs/faces-ko.png`. These are expression preview sheets, not screenshots of personal conversations or mail.
- The preview script uses **DejaVu Sans** ([Bitstream Vera / DejaVu notices](https://dejavu-fonts.github.io/License.html)) and **Noto Sans CJK** ([SIL Open Font License 1.1](https://github.com/notofonts/noto-cjk/blob/main/Sans/LICENSE)). Only rasterized output is tracked; font binaries are not included. Do not relicense or bundle the font software as MIT. Noto's OFL explicitly excludes documents created using the fonts from its font-license requirement.

## Optional ESP32 firmware

These dependencies are installed separately by the Arduino toolchain. They are not included as library source or compiled firmware in the tracked repository.

| Component | Upstream license / notice |
| --- | --- |
| Adafruit GFX | [BSD notice](https://github.com/adafruit/Adafruit-GFX-Library/blob/master/license.txt), copyright Adafruit Industries |
| Adafruit GC9A01A | [BSD statement](https://github.com/adafruit/Adafruit_GC9A01A/blob/main/README.md) and [source notice](https://github.com/adafruit/Adafruit_GC9A01A/blob/main/Adafruit_GC9A01A.cpp); Limor Fried/Ladyada for Adafruit Industries, GC9A01A adaptation by Phil “PaintYourDragon” Burgess |
| Adafruit BusIO (transitive dependency) | [MIT](https://github.com/adafruit/Adafruit_BusIO/blob/master/LICENSE) |
| Arduino-ESP32 core | [LGPL-2.1-or-later declaration](https://github.com/espressif/arduino-esp32/blob/master/package.json); included SDK components have their own notices |

Keeping project-owned sources MIT does not remove the firmware dependencies' obligations. Before publishing compiled `.bin` files, inventory the exact core, ESP-IDF, libraries and transitive components; provide their required notices, corresponding source and any relinking materials required by the applicable licenses. No compiled firmware is prepared for release by this documentation update.

## Assessment

No confirmed license conflict with publishing the project-owned source under MIT was found in this review. This is not a blanket clearance of a future app/firmware bundle of external material added later. Non-runtime housing materials and personal development notes have been excluded from this publication. Binary dependencies must still be checked for each release; runtime code and libraries were not removed.

Claude, ChatGPT, Codex, Apple and other product names remain their owners' trademarks. This project is not affiliated with or endorsed by those companies.
