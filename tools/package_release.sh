#!/bin/zsh
# Stage a Universal 2 download. Never installs, launches, or replaces the user's app.
set -eu
cd "${0:A:h}/.."
OUT="${1:-$PWD/release-artifacts}"
mkdir -p "$OUT"
OUT="${OUT:A}"
WORK="$(mktemp -d "$PWD/.aiface-build-release-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PACKAGE="$WORK/AI Face"
mkdir -p "$PACKAGE"
AIFACE_BUILD_ARCH=arm64 /bin/zsh tools/build_app.sh --stage
/usr/bin/ditto 'AI Face.update.app' "$PACKAGE/AI Face.app"
AIFACE_BUILD_ARCH=x86_64 /bin/zsh tools/build_app.sh --stage
for executable in MacOS/AIFace Helpers/InstallBridge; do
  /usr/bin/lipo -create "$PACKAGE/AI Face.app/Contents/$executable" \
    "AI Face.update.app/Contents/$executable" -output "$WORK/universal"
  mv "$WORK/universal" "$PACKAGE/AI Face.app/Contents/$executable"
  chmod 755 "$PACKAGE/AI Face.app/Contents/$executable"
done
/usr/bin/codesign --force --sign 'AI Face Local Signing' "$PACKAGE/AI Face.app/Contents/Helpers/InstallBridge"
/usr/bin/codesign --force --sign 'AI Face Local Signing' "$PACKAGE/AI Face.app"
/usr/bin/codesign --verify --deep --strict "$PACKAGE/AI Face.app"
cp LICENSE THIRD_PARTY_NOTICES.md "$PACKAGE/"
cp docs/INSTALL_RELEASE.md "$PACKAGE/INSTALL.md"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PACKAGE/AI Face.app/Contents/Info.plist")"
NAME="AI-Face-$VERSION-macOS-universal.zip"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PACKAGE" "$OUT/$NAME"
(cd "$OUT"; /usr/bin/shasum -a 256 "$NAME" > SHA256SUMS.txt)
echo "Created $OUT/$NAME"
