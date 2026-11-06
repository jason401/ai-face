#!/bin/zsh
# Source installer for the v2.2.0 release: builds AI Face on this Mac with this Mac's own signing
# identity, so the app can update itself from the stable branch afterwards (Update now).
# Contains no signing keys or personal data, and never asks for a password.
set -eu
set -o pipefail
RELEASE_TAG='v2.2.0'
REPOSITORY='https://github.com/jason401/ai-face.git'

finish() {
  local result=$?
  if (( result != 0 )); then
    print '\nInstallation stopped. Read the error above; your settings and history were not changed.'
  fi
  if [[ -t 0 ]]; then
    read -r '?Press Return to close this window. ' || true
  fi
}
trap finish EXIT

print "AI Face ${RELEASE_TAG} — build on this Mac"
print 'This creates (or reuses) a local code-signing identity; approve macOS prompts yourself.'
print 'An AI Face already in Applications that was signed on another Mac is quit and moved to the Trash.'
print 'Settings, history and photos stay. No password or API key is requested by this script.\n'

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  print -u2 'Install Apple Command Line Tools first: xcode-select --install'
  exit 1
fi
/usr/bin/python3 --version >/dev/null
CACHE_ROOT="$HOME/Library/Caches/AI Face"
mkdir -p "$CACHE_ROOT"
INSTALL_WORK=$(mktemp -d "$CACHE_ROOT/install.XXXXXX")
print "Source/build folder: $INSTALL_WORK/source"
/usr/bin/git clone --branch "$RELEASE_TAG" --single-branch "$REPOSITORY" "$INSTALL_WORK/source"
cd "$INSTALL_WORK/source"
/bin/zsh tools/setup_signing.sh
# The app's own update checkout (it follows the stable branch from now on).
/usr/bin/python3 tools/prepare_update_source.py
/bin/zsh tools/build_app.sh --stage < /dev/null
/usr/bin/python3 tools/first_install.py
print '\nDone. AI Face is in the menu bar. New versions: Settings → General → Check now, then Update now.'
