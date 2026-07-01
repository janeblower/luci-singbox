# Release Procedure

## i18n freshness check
Before tagging, regenerate translation templates from JS sources:
1. `bash scripts/regen-po.sh`
2. Open `luci-app-singbox-ui/po/ru/luci-singbox-ui.po`, translate any new untranslated entries.
3. `cd tests && bun run test:cross` must PASS — this runs `tests/cross/test_po_coverage.test.ts` (max 5 untranslated, max 5 drift).

## Tag & build

1. Ensure `main` is green. There is no single runner — tests are split across three lanes by execution environment:
   - `sh tests/run-vm.sh` — `tests/backend` + `tests/parity` (bun, in-guest OpenWrt QEMU).
   - `cd tests && bun run test:ui && bun run test:cross` — `tests/ui` + `tests/cross` (vitest, host).
   - `bash tests/cross/test_browser.sh` — `tests/browser` (Playwright, host Docker LuCI container).
2. Move `## [Unreleased]` entries in `CHANGELOG.md` into `## [vX.Y.Z] — YYYY-MM-DD`.
   Then re-add an empty `## [Unreleased]` block at the top of the changelog.
3. Commit: `git commit -am "docs: changelog vX.Y.Z"`.
4. Tag: `git tag -a vX.Y.Z -m "..." && git push origin main --tags`.
5. Push the tag — CI does the rest. `.github/workflows/build.yml` triggers on `v*` tags,
   runs `scripts/build-apk.sh`, and publishes a GitHub Release with all package `.apk`s attached
   (`softprops/action-gh-release`). A local build is `bash scripts/build-apk.sh`;
   the version comes from the tag, or per-package `PKG_VER_*` overrides in CI.
6. The apk feed on `gh-pages` is redeployed automatically by `.github/workflows/pages.yml`
   (triggered on Build success), which runs `scripts/build-feed.sh` + `scripts/publish-feed.sh`.

## SemVer rules

- **MAJOR**: a UCI-schema break without a migration.
- **MINOR**: new fields, sections, or protocol coverage — backwards compatible.
- **PATCH**: bug fixes only.

UCI-defaults migrations are required for any MINOR or MAJOR change to the schema, except for purely additive fields that the backend tolerates as missing.

## Build artifacts (apk-only)

The project is apk-only — there is no OpenWrt SDK / `.ipk` build path. A single
host-side build (`scripts/build-apk.sh`) produces **five** apk packages:

- `bbolt-client_<version>.apk` — the cache.db reader (the **only** per-arch package).
- `singbox-ui_<version>.apk` — noarch backend (ucode handlers, nftables, subscriptions).
- `luci-app-singbox-ui_<version>.apk` — noarch LuCI frontend (htdocs JS, ACL, menu).
- `luci-i18n-singbox-ui-ru_<version>.apk` — noarch Russian translation.
- `singbox-ui-plugin-awg_warp_<version>.apk` — noarch AWG/WARP plugin.

The Russian translation is a **separate** package: it is not bundled into the
frontend. End users installing generated `.apk`s directly should also install
`luci-i18n-singbox-ui-ru` for the translated UI. The feed installer (`install.sh`)
pulls the frontend plus the `-ru` translation automatically
(`apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru`).
