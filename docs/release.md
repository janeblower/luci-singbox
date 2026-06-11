# Release Procedure

## i18n freshness check
Before tagging, regenerate translation templates from JS sources:
1. `bash scripts/regen-po.sh`
2. Open `luci-singbox-ui/po/ru/luci-singbox-ui.po`, translate any new untranslated entries.
3. `bash tests/test_po_coverage.sh` must PASS (max 5 untranslated, max 5 drift).

## Tag & build

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

## Build artifacts: SDK vs host-side differences

The repo supports two build paths producing slightly different package
sets:

- **OpenWrt SDK build** (`make package/luci-singbox-ui/compile`):
  The Makefile bundles `po/ru/luci-singbox-ui.po` into the main
  `luci-singbox-ui.ipk` as `/usr/lib/lua/luci/i18n/luci-singbox-ui.ru.lmo`.
  Single package, single artifact.

- **Host-side build** (`scripts/build-apk.sh`):
  Produces **two** apk packages — the main app plus a separate
  `luci-i18n-singbox-ui-ru` for the Russian translation. Matches the
  layout used by the official OpenWrt feed for similar apps.

End users installing from a generated `.apk` from `scripts/build-apk.sh`
should also install the `-ru` package for the translated UI; SDK builds
include the translation by default.
