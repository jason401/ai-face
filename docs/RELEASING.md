# Release maintenance

Use `tools/package_release.sh` to stage a Universal 2 app ZIP and SHA256SUMS.txt in ignored `release-artifacts/`. It builds both app executables for arm64 and x86_64, combines them with lipo, signs with the existing AI Face Local Signing identity and verifies the bundle. It does not install or launch the result. Signing identity creation or private-key distribution is not part of packaging.

Before publishing:

1. Review a clean source commit; run unit/regression tests and the firmware simulator.
2. Build from that commit. Verify both executables' architectures and the deep/strict signature, extract a fresh archive, and compare its SHA-256. Scan the final app for personal paths and credentials. Include LICENSE, THIRD_PARTY_NOTICES.md and installation instructions.
3. Exercise installer transactions with disposable signed fixtures. Distinguish fixture checks, current-Mac validation and actual fresh-Mac/hardware testing in release notes. Do not claim a fresh Intel Mac test when only cross-compilation was performed.
4. Tag the actual build commit and prepare a draft release. Keep existing releases and assets. Only publish after the authorized release review.
5. Attach the Universal ZIP, SHA256SUMS.txt and readable installation instructions. Mark signing as local / not Apple notarized. State Command Line Tools / external Python prerequisites.

Downloaded apps use manual GitHub Release downloads for updates. The source-based in-app updater is for development installations with an existing local signing identity and follows stable, not release assets. Do not silently change this contract.

After an authorized Git privacy-history rewrite, existing developer and updater clones cannot simply pull the new history. Back up local work, verify the rewritten remote, and align those clones deliberately. An already-installed app may still reference an old source commit; preserve a local-only ancestry bridge when migrating its source updater, or migrate through the signed transactional installer. Never push the original private history back to the public remote.

Only the app, bundled project sources/firmware and required notices belong in the ZIP. Never package `.git`, personal support data, photos, logs, signing private keys, local privacy backups or development memos. Optional external firmware libraries/core are not bundled. A future compiled firmware release needs its own exact-version SDK/license inventory.

The packaging script does not install Python, enable Calendar/Mail/keep-awake, flash firmware, or alter login items. Those remain optional user-controlled features.
