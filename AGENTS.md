# AI Face development

Read `HANDOFF.md` for current installation status and `CLAUDE.md` for feature invariants.
Keep user data, `local.aiface`, existing AI Face Local Signing identity and MCP registration paths unchanged.
Runtime code lives in the signed bundle; never execute runtime code from the update checkout.
Build: `zsh tools/build_app.sh --stage` stages only; normal build installs through a transaction.
Tests: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests`; `bash tools/firmware_sim/run.sh`.
Installer live check: `PYTHONDONTWRITEBYTECODE=1 python3 tools/tests/install_live.py` (temporary signed fixture apps).
Commit tested changes to main; publish stable separately with `git push origin main:stable` (fast-forward only).
No development checkout may be changed by automatic updates. Preserve existing local signing keys.
No ad-hoc fallback. Do not flash firmware, modify Calendar/Mail permissions or set up keep awake without a request.
