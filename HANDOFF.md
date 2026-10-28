# AI Face — independent installation (2026-10-28)

Implementation: complete bundle at `/Applications/AI Face.app`, runtime scripts and firmware in Resources, native InstallBridge in Helpers, stable source checkout under Application Support. Developer checkout is never changed by the updater. Python and Command Line Tools remain external requirements for this personal source-build stage.

Installer reuses AI Illuminati's transaction design: verify current designated requirement, stage on destination volume, normal termination of the exact app, preserve/restore login registration, swap, require a matching revision acknowledgement from the new app after its bundled server responds, rollback on failure. Interrupted installs require explicit recovery; never overwrite their journal.

Final idle check freezes HTTP admissions while the old app quits, covering concurrent Calendar/Mail/photo requests as well as timer, keep-awake leases, pending Calendar approvals and firmware flashing. Server finishes cleanup before app exit; parent-death watchdog prevents orphan servers.

User data/MCP file paths and bundle ID unchanged; firmware flashing is not performed by app updates. Firmware builds work on a writable copy. Preserve the existing signing identity. Source trust remains the configured GitHub repository, not a pinned publisher signature. Developer ID/notarization/Sparkle/runtime bundling are follow-up scope.

Verified: 118 unit/regression tests, firmware simulator, and two real signed disposable-app installation/upgrade transactions pass. Initial user-app migration from the legacy bundle to `/Applications` completed at revision a2f721d. Same designated requirement, bundled Python server revision, ESP32 serial connection and login auto-start ON verified. Local backup under Application Support/migration-backups includes existing app/data/preferences (213 files). Fresh app startup with the entire developer folder temporarily renamed passed; developer folder restored immediately.

Actual stable update passed: installed app a2f721d -> Check now -> private stable checkout fetch/fast-forward -> all 118 regression tests -> local signed build -> normal quit -> replacement -> live server revision acknowledgement 3613ce9. Settings visibly show 2.1.0 (3613ce9), automatic updates ON and Open at login ON. ESP32 connected without firmware flashing. Installed signature passes deep/strict validation and the original designated requirement.

After update, all 213 pre-migration files were compared again: 0 missing; only controller.json and update.json changed as expected. Settings/photos/history and MCP shim files unchanged. Both private source checkout and developer working tree were clean before recording these documentation notes.

Stable runtime release is 3613ce9. This final verification documentation is main-only so it does not trigger another app rebuild/restart. Existing app, preferences and data remain backed up locally. The previous project-folder app is retained as a recovery copy; do not launch it while the installed app is running.

Scope: current-Mac migration is verified. Other-Mac legacy login-item migration and fresh signing identity bootstrap need separate testing before treating this as general public binary distribution. Current builds require the existing signing identity, Python and Command Line Tools.
