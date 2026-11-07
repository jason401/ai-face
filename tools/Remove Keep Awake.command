#!/bin/zsh
# AI Face "Keep awake": removes the sudoers rule and the `awake` command (Settings → AI →
# Keep awake → Remove…). Terminal opens a .command file without arguments, hence this file.
exec /bin/zsh "${0:A:h}/Set up Keep Awake.command" remove
