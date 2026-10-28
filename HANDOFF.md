# AI Face — independent installation (2026-10-28)

Implementation: complete bundle at `/Applications/AI Face.app`, runtime scripts and firmware in Resources, native InstallBridge in Helpers, stable source checkout under Application Support. Developer checkout is never changed by the updater. Python and Command Line Tools remain external requirements for this personal source-build stage.

Installer reuses AI Illuminati's transaction design: verify current designated requirement, stage on destination volume, normal termination of the exact app, preserve/restore login registration, swap, require a matching revision acknowledgement from the new app after its bundled server responds, rollback on failure. Interrupted installs require explicit recovery; never overwrite their journal.

Final idle check freezes HTTP admissions while the old app quits, covering concurrent Calendar/Mail/photo requests as well as timer, keep-awake leases, pending Calendar approvals and firmware flashing. Server finishes cleanup before app exit; parent-death watchdog prevents orphan servers.

User data/MCP file paths and bundle ID unchanged; firmware flashing is not performed by app updates. Firmware builds work on a writable copy. Preserve the existing signing identity. Source trust remains the configured GitHub repository, not a pinned publisher signature. Developer ID/notarization/Sparkle/runtime bundling are follow-up scope.

Verified: 118 unit/regression tests, firmware simulator, and two real signed disposable-app installation/upgrade transactions pass. Initial user-app migration from the legacy bundle to `/Applications` completed at revision a2f721d. Same designated requirement, bundled Python server revision, ESP32 serial connection and login auto-start ON verified. Local backup under Application Support/migration-backups includes existing app/data/preferences (213 files). Fresh app startup with the entire developer folder temporarily renamed passed; developer folder restored immediately.

Next verification: publish the corrected update explanation/version display and upgrade the installed app through its stable checkout.
