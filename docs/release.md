# Release Procedure

1. Ensure `main` is green: `bash tests/run-docker.sh` returns PASS.
2. Move `## [Unreleased]` entries in `CHANGELOG.md` into `## [vX.Y.Z] — YYYY-MM-DD`.
   Then re-add an empty `## [Unreleased]` block at the top of the changelog.
3. Commit: `git commit -am "docs: changelog vX.Y.Z"`.
4. Tag: `git tag -a vX.Y.Z -m "..." && git push origin main --tags`.
5. Build the apk: `bash scripts/build-apk.sh` (the version is picked up from the tag automatically).
6. Create a GitHub Release with the apk attached. (Phase D will automate this step via CI.)

## SemVer rules

- **MAJOR**: a UCI-schema break without a migration.
- **MINOR**: new fields, sections, or protocol coverage — backwards compatible.
- **PATCH**: bug fixes only.

UCI-defaults migrations are required for any MINOR or MAJOR change to the schema, except for purely additive fields that the backend tolerates as missing.
