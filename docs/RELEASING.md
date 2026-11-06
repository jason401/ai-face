# Release maintenance

Releases are **source installation packages**, like AI Illuminati's: the ZIP holds the tagged source and `Install AI Face.command`, which clones that tag, creates or reuses the user's own **AI Face Local Signing** identity (`tools/setup_signing.sh`), prepares the app's private stable checkout (`tools/prepare_update_source.py`), builds and installs (`tools/first_install.py`). Because each Mac signs with its own identity, the in-app updater (stable branch, Update now) works on every installation. No signing key is ever distributed.

Steps:

1. Set the version in `tools/build_app.sh` (`CFBundleShortVersionString`) and `RELEASE_TAG` in `Install AI Face.command`; update README download links.
2. Run the unit tests and the firmware simulator on a clean commit; push `main` (and `stable` when it is the shipped version).
3. Tag that commit (`git tag vX.Y.Z && git push origin vX.Y.Z`).
4. `zsh tools/package_release.sh vX.Y.Z` writes `release-artifacts/AI-Face-X.Y.Z-source.zip` (git archive of the tag: no `.git`, ignored or locally excluded files) and `SHA256SUMS.txt`, after checking the tag's installer and version and scanning for secrets.
5. Publish the release with those two files. Mark it as a source installation; state that signing is local, not Apple notarized, and what was actually tested (fixture tests vs a real fresh Mac).

`tools/first_install.py`: no app → install; an app signed by another identity (the old 2.1.0 download) → quit, move to the Trash, install; an app signed with this Mac's identity → left alone (it changes only through its own updates).

After an authorized Git privacy-history rewrite, existing developer and updater clones cannot simply pull the new history. Back up local work, verify the rewritten remote, and align those clones deliberately. An already-installed app may still reference an old source commit; preserve a local-only ancestry bridge when migrating its source updater, or migrate through the signed transactional installer. Never push the original private history back to the public remote.

Only tracked project files belong in the ZIP. Never package `.git`, personal support data, photos, logs, signing private keys, local privacy backups or development memos. Optional external firmware libraries/core are not bundled. A future compiled firmware release needs its own exact-version SDK/license inventory.

The packaging script does not install Python, enable Calendar/Mail/keep-awake, flash firmware, or alter login items. Those remain optional user-controlled features.
