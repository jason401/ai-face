#!/bin/zsh
# First installation: builds AI Face and installs it in /Applications. After that the app updates
# itself from the stable branch, and running this again only builds a test copy (AI Face.update.app).
exec /bin/zsh "${0:A:h}/tools/build_app.sh"
