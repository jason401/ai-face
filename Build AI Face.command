#!/bin/zsh
# First installation from a source checkout: builds AI Face and installs it in /Applications (an app
# signed on another Mac is replaced). After that the app updates itself from the stable branch, and
# running this again only builds a test copy (AI Face.update.app). Needs tools/setup_signing.sh once.
exec /bin/zsh "${0:A:h}/tools/build_app.sh"
