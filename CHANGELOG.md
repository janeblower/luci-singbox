# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## Phase G — Unified qemu test rig (2026-06-09)

- **CI test surface unified** to a single environment: a pre-built ghcr.io
  Docker image (`openwrt-test:openwrt-25.12.3-<sha>`) that boots real OpenWrt
  25.12.3 under QEMU/KVM from a baked memory snapshot. The host's working
  tree is tar-streamed into the guest; the suite runs inside.
- **`tests/run-docker.sh` removed.** `tests/run-vm.sh` is the new long-form
  entry; `tests/run.sh` delegates to it when ucode is not on host.
- **Sentinel renamed:** `SINGBOX_TESTS_IN_DOCKER` → `SINGBOX_TESTS_IN_VM`.
- **Phase 0 unblock:** `SC2086` warnings fixed in three nft tests
  (`test_nftables_ctmark.sh`, `test_nftables_ip_rule_smoke.sh`,
  `test_nftables_uc.sh`) using the established disable-comment pattern.
- **New workflow** `.github/workflows/test-image.yml` builds + publishes the
  test image on `workflow_dispatch` or on changes to `tests/docker/**`.
- **Browser-test migration** to qemu-LuCI is intentionally **out of scope** —
  separate follow-up plan.

#### Breaking change for contributors

Running `tests/run.sh` on a host without `/dev/kvm` no longer falls back to
a host-only subset run inside `openwrt/rootfs`. Either run tests on a host
with KVM, or set `SINGBOX_TESTS_IN_VM=1` to bypass the delegation (and
accept the SKIPs that come with no ucode).

## Unreleased — Phase F (nftables ctmark refactor)

**Breaking (integrators only):** The two-chain layout
`prerouting_mark` (priority -150) + `prerouting_tproxy` (priority
-149) is replaced by a single `prerouting` chain at `priority
mangle`. If you had external nft commands or other LuCI apps that
hooked these chain names (rare but possible), retarget them at
`prerouting` / `output`.

- **nft**: per-flow decision via `ct mark`; `meta mark` only propagates
  the bit into the TPROXY match.
- **nft**: `socket transparent 1` fast-path for established flows
  (requires `kmod-nft-socket`, now an explicit package dependency).
- **nft**: TPROXY match uses `meta mark and $MASK == $MARK` — coexists
  with mwan3 / SQM / pbr without bit collisions.
- **uci**: new options on `singbox-ui.@global[0]`:
  - `fwmark` (hex, default `0x1`)
  - `fwmark_mask` (hex, default `0x1`)
  - `redirect_router_traffic` (`0`/`1`, default `0`)
- **uci-defaults**: new `90-singbox-ui-fwmark` seeds the three options
  on upgrade (defaults reproduce the prior behaviour).
- **pkg**: depend on `+kmod-nft-socket` and explicit `+kmod-nft-tproxy`.
- **fix**: rs_* rules now mark on a per-flow basis. Previously
  established UDP and post-handshake TCP packets escaped the mark
  because `ct state new` was filtering but `meta mark` was being
  stored — this is what the refactor was triggered to fix.
- **infra**: log-only smoke check after `nft -f` warns when no matching
  `ip rule fwmark…` is found.
- **tests**: new `tests/test_nftables_ctmark.sh` structural guards,
  `tests/test_uci_defaults_fwmark.sh` migration test,
  `tests/test_nftables_ip_rule_smoke.sh` smoke-check test.
- **docs**: README — operator section on `ip rule` requirement and
  router-traffic redirect.

## Unreleased — Phase E3 (browser tests, full coverage)

- **infra**: rewrote `tests/test_browser.sh` to drive a Docker container
  (`openwrt/rootfs:x86_64-25.12.3` + uhttpd + rpcd + sing-box) instead of
  SSH-deploying to a live VM. One harness, identical locally and in CI.
- **infra**: switched `tests/browser/` from npm to bun; `trustedDependencies`
  controls postinstall script execution.
- **tests**: added per-protocol matrix (7 inbound, 5 outbound) for builder
  field surfaces and `preview_config` emit shape. Total 20 browser tests.
- **ci**: new `browser-test` job in `.github/workflows/build.yml`.
- **docs**: `tests/browser/README.md` for local-run / debug.
- **fix**: `hysteria2.uc` inbound `server_password` ui_label changed from
  `"Password (single user)"` to `"Password"` — the parenthetical was
  silently dropped by `applyMaterialized`'s shared-key dedup (shadowsocks
  registers `Password` first); this aligns descriptor truth with rendered UI.

## Phase E2 — Protocol Builder Rewrite (2026-06-09)

### Added
- Full sing-box 1.12 field coverage for every UI-exposed protocol via the new shared TLS / transport / multiplex / dial blocks under `lib/protocols/_shared/`.
- Mixed inbound (HTTP + SOCKS5 on one port) with optional user/pass auth.
- Direct outbound (interface bind via dial fields) — replaces the old `type=interface` outbound.
- `hysteria2://` share-link parser.
- Per-tab "Show advanced fields" toggle (TLS / Transport / Multiplex / Dial).
- Subscription expand: child rows now render automatically on outbounds-tab load (previously required clicking action-bar Refresh).

### Changed
- Protocol descriptor DSL extended: per-field `tab`, `advanced`, `depends`, `parent_enabled`, `placeholder`, `virtual`; per-descriptor `shared` map declaring which shared blocks the protocol composes with.
- `lib/inbound.uc` and `lib/outbound.uc` are now descriptor-only — no per-protocol switch, no hand-coded TLS/transport/multiplex helpers.

### Removed
- TUN inbound, VMess inbound/outbound, TUIC outbound, AnyTLS outbound, SSH outbound, interface outbound. Existing UCI sections of these types are hard-deleted by the `drop-removed-protocols-e2` migration on upgrade. Legacy UCI keys on surviving protocols (`transport`, `security`, `tls_ech`, `utls_fingerprint` etc.) are renamed by `migrate_rename_e2_keys`.

### Fixed
- Subscription child rows now align with the parent grid columns and have a visible nesting indicator.
- Hysteria2 obfs UCI key parity in share-link / JSON import (`obfs_type` / `obfs_password`, not legacy `hysteria2_obfs_*`).
- Shadowsocks SIP002 base64 userinfo decoded by the share-link import.

## Phase E1 — Grid / Builder / Subscriptions cleanup + D3 revert (2026-06-08)

- Grid columns trimmed to Enable / Name / Type / Address / JSON
  (`tests/test_grid_columns.sh` enforces).
- Modal builder fixed: descriptor fields use `modalonly=true` and
  dedupe by UCI key, so VLESS/VMess/Trojan/etc. modals show their
  expected basic+credentials layout instead of only the Credentials/Flow
  case caused by SSH's group-less fields.
- SSH descriptor: explicit `group` per field.
- Subscriptions: `subscription_expand` RPC + `lib/subscription_view.js`
  inject read-only child rows under each subscription outbound in the
  grid, with a View button opening a read-only modal.
- D3 token-based reveal removed. `lib/reveal.uc`, `lib/scrub.uc`, the
  `reveal_token_grant`/`reveal_token_revoke` RPC methods, the action-bar
  Show/Hide secrets button, `withRevealToken`/`revealGrant`/`revealRevoke`
  in `lib/rpc.js`, and the D3.7 storage-leak test guards — all gone.
  Masking now lives only in the modal as `<input type="password">` +
  a client-side eye-toggle (`decorateSecretInput` in `descriptor_form.js`).
- Preview/read_config/export_section return plain JSON.

## [Unreleased]

Phase B — completion of protocol field coverage, JSON export, form
validation, share-link parsers, and a pre-apply dry-run preview.

### Added

**TLS**
- ECH support on inbound (`tls_ech_key` list, `tls_ech_key_path`) and outbound (`tls_ech_config` list, `tls_ech_config_path`).
- TLS fragment options on outbound (`tls_fragment`, `tls_fragment_fallback_delay`, `tls_record_fragment`) — Since sing-box 1.12.

**Hysteria2**
- `brutal_debug` on both inbound and outbound.
- `ignore_client_bandwidth` on inbound.
- `network` restriction (`tcp` / `udp`) on outbound.

**TUIC**
- New TUIC outbound: `congestion_control`, `udp_relay_mode` and `udp_over_stream` (mutually exclusive), `zero_rtt_handshake`, `heartbeat`, `network`.

**Shadowsocks**
- Inbound multi-user via `list ss_user 'name:method:password'`.
- Inbound `network` restriction.
- Inbound `multiplex` block.

**AnyTLS**
- New AnyTLS outbound (Since sing-box 1.12) with idle session management (`idle_session_check_interval`, `idle_session_timeout`, `min_idle_session`).

**VMess / VLESS multi-user inbound**
- `list inbound_user 'name:uuid[:alterId]'` for VMess and `list inbound_user 'name:uuid[:flow]'` for VLESS.

**UI**
- Form validators in `lib/validators.js`: `isPort`, `isUuid`, `isHost`, `isAlpnNonEmpty`, `requiresWsPath`, plus a warn-only `softWarnCongestion` for unknown congestion-control values. Wired into the inbound and outbound tabs.
- Per-row "Export JSON" button on inbounds and outbounds — calls new `singbox-ui::export_section` RPC, opens a modal with a Copy button.
- Action-bar "Preview config" button — calls new `singbox-ui::preview_config` RPC, opens a modal with the full generated `config.json` and a Copy button. Dry-run does not write `/etc/sing-box/config.json`, does not touch nftables, and does not restart the service.

**Share-link parsers**
- `vmess://` (base64-JSON v2rayN variant, both `aid` and `alterId` accepted).
- `ss://` (plain `method:password@host:port#name` and base64 userinfo).
- `trojan://` (with `sni`, `type=ws`, `path` parameters).

### Changed

- VMess inbound users[] now emits `alterId` (camelCase) instead of `alter_id`, matching the sing-box 1.12 documented schema. Outbound legacy single-user `alter_id` retained.
- Inbound `tls.reality.short_id` is now emitted as a single string (was wrapped in a single-element array) per sing-box 1.12 schema. Outbound was already correct.

### Fixed

- Reality `short_id` JSON shape on inbound (single string, not array).

### Docs

- New `docs/protocol-coverage.md` matrix tracking every protocol field × inbound/outbound × status (`есть` / `нет` / `out-of-scope`) for sing-box 1.12.
- `docs/uci-schema.md` updated with all Phase B UCI fields (ECH, fragment, brutal_debug, ignore_client_bandwidth, TUIC fields, AnyTLS fields, Shadowsocks multi-user, VMess/VLESS multi-user, multiplex on shadowsocks inbound).

### Tests

- ucode unit coverage for every new field across `tests/test_inbounds_uc.sh` and `tests/test_outbound_constructor.sh`.
- End-to-end `tests/test_generate.sh` scenarios for ECH, hysteria2 obfs/brutal_debug, multi-user vmess/vless inbound.
- `tests/test_subscription_uc.sh` cases for the new vmess/ss/trojan parsers (one positive, one malformed input each).
- `tests/test_rpcd_handler.sh` cases for `export_section` and `preview_config` (no FS side effects).
- `tests/test_validators_js.sh` for the pure-function validators (skipped where `node` is absent).

---

Phase C1 — security and UX hardening: secret scrubbing on RPC output,
split read/write Clash proxy methods, share-link parser input sanitization,
non-destructive JSON import, and full Russian translation coverage.

### Security (Phase C1)

- **`preview_config` and `export_section` RPC handlers now scrub secrets by default.** Sensitive keys (`uuid`, `password`, `private_key`, `public_key`, `short_id`, `key_pem`, `cert_pem`, `secret`, `auth_str`, `proxy_url`, `sub_url`) are masked as `"***"` before the response leaves rpcd. Read-ACL LuCI users no longer see verbatim credentials.
- **Share-link parsers harden against malicious input.** `url_decode` drops control characters (`< 0x20`) and a new `drop_ctrl()` helper protects the `ss://` base64 plaintext paths. Parsers (`vless://`, `vmess://`, `trojan://`, `ss://`, `hy2://`) validate host (`safe_host`), port (`safe_port`), and tag (`safe_tag` with `imported-<fnv1a>` fallback). Hostile subscription servers can no longer inject NUL/CR/LF into UCI fields.

### Changed (BREAKING)

- **RPC method `clash_request` removed and replaced by `clash_get` + `clash_mutate`.**
  - `clash_get` — GET only, `read.ubus` ACL. Refuses any `method` argument (defense in depth so a read-only caller cannot upgrade to write).
  - `clash_mutate` — POST/PATCH/PUT/DELETE only, `write.ubus` ACL. Refuses GET.
  - Frontend (`lib/rpc.js`, `tabs/monitoring.js`) migrated. Any external caller of `clash_request` must update to the new split methods.

### Added (Phase C1)

- `lib/scrub.uc` — central secret-masking helper used by RPC output paths. Pure function, returns a new object, leaves paths untouched (only inline secret content is masked).
- `lib/helpers.uc::fnv1a32` — promoted from `nftables.uc` to be the single FNV-1a implementation, now reused by share-link parsers.
- `scripts/regen-po.sh` — one-shot xgettext + msgmerge for keeping Russian translations in sync with JS sources.
- `tests/test_scrub_uc.sh` — 12 cases covering scrub recursion, idempotency, path preservation, reality keys, cert pem.
- `tests/test_acl_coverage.sh` — pins read/write ACL membership against safety whitelists.
- `tests/test_po_coverage.sh` — enforces |JS-po| ≤ 5 drift and ≤ 5 untranslated msgstr.

### Fixed (Phase C1)

- JSON import in inbound/outbound tabs no longer calls `window.location.reload()`. The importer stages the new section into `uci.state` only; the user must press Save & Apply to commit. Previously, importing a section discarded any unsaved edits in other sections.
- `tests/test_view_modules_layout.sh` enforces the no-`location.reload` invariant.

### i18n

- Russian translation coverage expanded from ~40% to 100% (211 msgid in `po/ru/`, 0 untranslated, 4 drift). All Phase B and C1 strings translated, stale `#~` entries removed.
- Pre-release i18n freshness step added to `docs/release.md`.

---

Phase C2 — Important fixes (~25 backend/UI/build items) and minor sweep
(~16 documentation/build items). Atomic config publish, single-commit
migrations with `schema_version` sentinel, share-link hardening, RPC
read-path scrub completion, frontend polish (form tabs, busy state,
debounce), single install-manifest, `sing-box check` on generated configs.

### Security (Phase C2)

- `read_config` RPC handler now scrubs secrets in the same way
  `preview_config` and `export_section` do (gap identified in the C1
  final review). Read-ACL LuCI users no longer see verbatim credentials
  when viewing the on-disk `/tmp/singbox-ui.json`.
- `is_singbox_running()` queries procd via `ubus call service list`
  first, falling back to `pgrep -x sing-box` (basename match only). The
  previous `pgrep -f "sing-box run"` false-positived on any process
  whose commandline contained that string (including shells/editors).
- Local rule-set paths are restricted to under `/etc`, `/tmp`, `/var`,
  `/usr/share`. UCI `ruleset` `local_path` can no longer be pointed at
  `/etc/shadow` or similar via a hostile config.
- nftables emitter validates `listen_port` (int `1..65535`) and iface
  names (`^[A-Za-z0-9_.@-]+$`) before splicing them into rules. Argv
  injection via crafted UCI is no longer possible at the nft layer.
- `preview_config` tmpfile uses `mktemp(1)` (atomic `O_EXCL`); the
  previous time+urandom path used `fs.open(..., "w")` which lacks
  `O_EXCL`, opening a theoretical symlink race.
- Subscription URL accept is case-insensitive; `try_b64_decode`
  requires a recognized share-link scheme (`vless://`, `vmess://`,
  `trojan://`, `ss://`, `hy2://`, `hysteria2://`) to decode. Plaintext
  subscription bodies that happen to contain `://` are no longer
  silently mangled.

### Changed (Phase C2)

- Generated `/tmp/singbox-ui.json` is now written via `tmp + rename`.
  A SIGKILL mid-write no longer leaves a truncated config that
  sing-box refuses to start. The previous generation is retained as
  `.prev` for one-generation rollback.
- `etc/uci-defaults/99-...` migrations now guarded by
  `_meta.schema_version` (CURRENT_SCHEMA=15); re-runs short-circuit.
  All `uci commit` calls consolidated to a single commit at end of
  script — partial migration state on power-loss is no longer
  representable.
- `init.d::start_service` calls `nftables.uc remove` defensively
  before deciding whether to apply, so a config flipping from
  tproxy-required to direct-only no longer leaves stale nft tables.
- `lib/clash.uc` brackets IPv6 listen addresses for
  `external_controller` (was emitting `::1:9090` style, which clients
  parsed as host `::1` port `9090` or hostname `::1:9090` depending on
  client).
- `lib/helpers.uc::resolve_iface_device` caches results module-scope,
  reset on each `generate.uc` run — eliminates repeated `ubus`/UCI
  lookups during outbound emission.
- `is_outbound_proxy_kind()` + `OUTBOUND_PROXY_KINDS` constant in
  `lib/helpers.uc` is now the single source of truth for membership
  of the 7 proxy outbound types (vless / vmess / trojan / hysteria2 /
  shadowsocks / tuic / anytls). Replaces ad-hoc inline lists in
  `subscription.uc` and `generate.uc`.
- `nftables.uc::nft delete table` now uses argv form (consistent with
  the rest of the file).
- `detect_rs_format` strips URL query and fragment before suffix
  check, so `https://.../rules.srs?token=...` is detected as `binary`
  rather than `unknown`.

### Frontend / UX (Phase C2)

- Inbound and outbound modal forms grouped into 6 tabs (basic /
  credentials / TLS / transport / multiplex / advanced) via LuCI
  `s.tab(...)`. The modal is no longer 50 fields of vertical scroll.
- Both "Preview generated config" (`read_config`) and "Preview config
  (dry-run)" (`preview_config`) buttons now go through the same
  `showJsonModal({error|json})` helper — consistent error display and
  copy affordance.
- New `withBusy(btn, label, fn)` helper in `lib/common.js`; all
  long-running RPC handlers (preview, fetch-subs, restart) disable
  the button and show a busy label for the duration.
- `fallbackCopy` and `copyToClipboard` deduplicated into
  `lib/common.js` (previously duplicated across importers).
- Inline `<style>` blocks extracted to
  `htdocs/luci-static/resources/view/singbox-ui/style.css`; Makefile
  installs it.
- `softWarnCongestion` now shows `L.ui.addNotification` (user-visible)
  instead of `console.warn` (invisible to operators).
- `monitoring` search input is debounced at 200 ms and preserves
  scroll position on repaint.
- `addRenameField` rejects renames that collide with an existing
  section of the same kind (was producing UCI rename errors after Save).
- Removed dead `loadOutboundList` aliases from `tabs/inbounds.js` and
  `tabs/outbounds.js` (already moved to `lib/common.js` in Phase A).
- `transport_*` fields' `depends()` chains now require BOTH the
  protocol/type AND the transport selector, so transport-specific
  fields no longer leak onto sections whose protocol does not support
  the chosen transport.
- `validateAlpn` replaces `isAlpnNonEmpty`: empty ALPN list is now
  accepted (sing-box treats empty as default), and only known
  protocol entries are validated (`http/1.1`, `h2`, `h3`).
- `rulesets.js`: `nft_rules` flag now has a description tooltip.
- `main.js`: `setTimeout(fn, 0)` replaced with
  `Promise.resolve().then()` microtask.

### Build / CI / Docs (Phase C2)

- `scripts/install-manifest.txt` is the single source of truth for the
  install file set. `Makefile` and `scripts/build-apk.sh` both consume
  it via `while read`. New `tests/test_install_lists_match.sh`
  asserts the parity invariant between the two paths.
- `tests/test_generate.sh` runs `sing-box check` on every generated
  config in Docker mode — catches the entire class of "shape looks
  right but the daemon rejects it" bugs.
- `Makefile` ships a `preinst` hook that warns the operator before
  removing the conflicting `firewall` package via `PKG_CONFLICTS`.
- `README.md` gains an English overview block at the top (existing
  Russian content preserved below).
- `docs/release.md` documents the SDK-vs-host build artifact
  difference (host build also produces a separate
  `luci-i18n-singbox-ui-ru` package).
- `docs/protocol-coverage.md` dead links to the gitignored
  `docs/superpowers/` tree removed.
- `.gitignore` no longer self-ignores `.gitignore`.
- `etc/uci-defaults/99-...` cron interval is a named constant
  (`CRON_INTERVAL_MIN`).
- `.github/workflows/build.yml` lints `etc/uci-defaults/99-...` with
  `shellcheck --shell=ash` to catch ash-incompatible constructs (the
  runtime is busybox ash, not bash).

### Tests (Phase C2)

- New: `tests/test_install_lists_match.sh`.
- Extended: `tests/test_generate.sh` (orphan tmpfile detection +
  `sing-box check` on generated configs),
  `tests/test_uci_defaults_migration.sh` (`schema_version` sentinel +
  single-commit invariants), `tests/test_nftables_emit.sh` and
  `tests/test_nftables_uc.sh` (listen_port + iface name validation),
  `tests/test_subscription_uc.sh` (rule-set path whitelist +
  strict b64 heuristic + case-insensitive URL + `detect_rs_format`
  query strip), `tests/test_rpcd_handler.sh` (procd-based running
  detect, `mktemp`-backed preview, `read_config` scrub,
  `OUTBOUND_PROXY_KINDS` membership).
- `tests/test_validators_js.sh`: `validateAlpn` replaces
  `isAlpnNonEmpty`; total assertion count is now ~44.

### Deferred to Phase C3

- The wholesale rewrite of `lib/*.uc` emit paths to use only
  `s_opt` / `s_num` / `s_bool` helpers (item C2.3.3 in the plan)
  naturally lands as part of the schema-driven protocol descriptors
  in Phase C3.1, so it is deferred rather than landed here.

---

Phase C3 — architecture foundations: protocol descriptor registry,
post-processing pipeline, structured logging, status_detail RPC,
capability drop, auto-generated install manifest. Scope intentionally
focused on architecture infrastructure; wholesale per-protocol migration
and frontend descriptor-driven rendering tracked as Phase D work.

### Added (Phase C3)

- `lib/post_process.uc` — centralised post-build pipeline. The
  implicit-direct scrub (previously inline in `generate.uc`) now runs
  here, extended to cover `route.rules[].outbound`, `route.final`, and
  `dns.detour` in addition to the original `dns_server.detour`.
- `lib/log.uc::log_event(level, event, kv)` — structured event logger
  that writes via busybox `logger -t singbox-ui`. Format:
  `event=<n> ts=<unix> key=val ...`. Wired into `generate.uc` success,
  `rpcd` error paths, and `uci-defaults` migration completion. Mockable
  via `_set_logger_for_test()` for unit tests.
- `singbox-ui::status_detail` RPC — returns running flag, last_generate
  timestamp, last_apply_result, config_hash placeholder, schema_version,
  package_version, service_start_ts, and current `now`. Backed by
  `/var/lib/singbox-ui/{last_state,service_state}.json` written by
  `generate.uc` and `init.d` respectively.
- `lib/protocols/registry.uc` + `lib/protocols/ssh.uc` — descriptor
  framework + first reference descriptor (new SSH outbound, sing-box
  1.12+). `lib/outbound.uc::build_constructor_for` now consults the
  registry first; falls through to the legacy switch when no descriptor
  is registered. Migration of the 7 existing proxy outbounds to
  descriptors is Phase D incremental work.
- `/etc/capabilities/singbox-ui.json` — minimal capability set
  (`CAP_NET_ADMIN` + `CAP_NET_RAW` + `CAP_NET_BIND_SERVICE`). init.d
  wires it via `procd_set_param capabilities`. Sing-box no longer needs
  full root. Drop to `user=nobody` deferred (would require fixing
  `/tmp/singbox-ui.json` ownership).
- `scripts/gen-manifest.sh` — auto-generates `scripts/install-manifest.txt`
  by scanning `luci-singbox-ui/`. Mode auto-detection
  (bin / conf / data); manual overrides via
  `scripts/install-manifest-overrides.txt`.
- `tests/test_post_process_uc.sh`, `tests/test_log_uc.sh`,
  `tests/test_status_detail.sh`, `tests/test_capability_drop.sh`,
  `tests/test_install_manifest_fresh.sh`,
  `tests/test_protocol_descriptors.sh` — six new test files covering
  the foundation tasks.
- `docs/protocol-descriptors.md` — reference for writing protocol
  descriptors.

### Changed (Phase C3)

- `generate.uc` no longer scrubs implicit-direct references inline; it
  collects implicit tags and calls `lib/post_process.uc::run_pipeline`.
- `etc/uci-defaults/99-...` `CURRENT_SCHEMA` bumped to 16 (marker for
  the Phase C3 metadata additions; no new structural migrations).

### Deferred to Phase D

- **Wholesale protocol migration to descriptors** (originally C3.1
  Tasks 9-15) — the registry is in place; migrating each existing
  protocol is an incremental task. The dispatcher in `lib/outbound.uc`
  falls through cleanly to the legacy switch for any type not in the
  registry, so descriptors can land one at a time without coordinated
  cuts.
- **Frontend descriptor-driven form rendering** (originally C3.1
  Task 16) — depends on the per-protocol descriptors landing first.
- **Secret-reveal UX with 5-minute token** (originally C3.7) — token
  storage, RPC method, and UI toggle. Substantial work that depends on
  the existing scrub working end-to-end (it does, since C1).
- **Plugin scaffolding + auto-detect-geo POC** (originally C3.8) —
  foundation for easy-mode UX. Picks up naturally after Phase D opens.

### Tests

- 28 test files now; new files: post_process, log, status_detail,
  capability_drop, install_manifest_fresh, protocol_descriptors.
- Full suite passes in the OpenWrt rootfs Docker harness.

---

Phase D — descriptor migration of the 7 proxy protocols (outbound first
in D1, inbound in D1.5), descriptor-driven UI in D2, secret-reveal UX
with TTL token in D3, plugin scaffolding in D4. `[Unreleased]` accumulates
sub-phase entries as work lands.

### Added (Phase D)

- `lib/protocols/{trojan,shadowsocks,vless,vmess,hysteria2,tuic,anytls}.uc` —
  outbound descriptors for the 7 proxy protocols. Each registers via
  `lib/protocols/registry.uc` at module load; `lib/outbound.uc::build_constructor_for`
  now consults the registry only — no per-protocol switch arms remain.
- `tests/test_protocol_field_coverage.sh` — drift guard between registered
  descriptor fields and `docs/protocol-coverage.md`. Caught real gaps in
  the doc which were filled in the same commit (per-protocol UCI columns
  for all 7 outbounds + new ssh outbound section).

### Changed (Phase D)

- `lib/outbound.uc::build_constructor_for` reduced to a registry-lookup
  dispatcher (10 lines of body). `test_view_modules_layout.sh` enforces
  the dispatcher-size invariant (≤14 lines including header/braces).
  `build_tls_client`, `build_transport`, `build_multiplex` exported so
  descriptors can reuse them.
- `docs/protocol-coverage.md`: 7 per-protocol outbound sections now have
  explicit UCI field columns; new ssh outbound section added.

### Added (Phase D — D1.5)

- Inbound descriptors appended to `lib/protocols/{trojan,shadowsocks,vless,vmess,hysteria2}.uc`.
  Each protocol module now registers BOTH outbound and inbound sides of
  the registry. Multi-user inbound modes (`ss_user` for shadowsocks,
  `inbound_user` for vless/vmess) preserved with first-colon split parsing
  identical to legacy. tuic / anytls inbound are out-of-scope per
  `docs/protocol-coverage.md` (not implemented in legacy either).
- `lib/inbound.uc` exports shared emit helpers (`build_user`,
  `build_inbound_users`, `build_tls`, `build_transport`, `build_multiplex`,
  `build_one`) so descriptors can call them.

### Changed (Phase D — D1.5)

- `lib/inbound.uc::build_one` now consults the protocol registry first
  (keyed on `s_opt(s, "protocol")`); legacy switch retains only
  infrastructure types `tproxy` / `tun` / `direct` plus the default
  warn-and-skip. Invariant documented in-line.

### Added (Phase D — D2)

- `singbox-ui::protocol_schema` RPC (read ACL) — returns the descriptor
  projection from `lib/protocols/schema_dump.uc`. Response shape:
  `{status, version:1, schema:{outbound:{...}, inbound:{...}}}`.
  `emit` functions are explicitly dropped via a whitelist of declarative
  keys (`name`, `type`, `required`, `default`, `validate`, `group`,
  `ui_label`, `secret`, `values`, `item`).
- `htdocs/.../lib/descriptor_form.js` — pure helper `applyDescriptor(s, kind, protoName, descriptor)`
  that creates LuCI `s.taboption()` widgets from descriptor metadata and
  wires depends on the right UCI key (`type` for outbound, `protocol` for inbound).
- `tests/test_protocol_schema_rpc.sh`, `tests/test_descriptor_form_js.sh` —
  RPC response shape + JS form-helper unit tests (node SKIP-aware).

### Changed (Phase D — D2)

- `tabs/outbounds.js` (-255 lines) and `tabs/inbounds.js` (-250 lines)
  no longer hand-code per-protocol `depends('type'|'protocol', '<proto>')`
  chains for descriptor-owned types. Each tab keeps its 6 `s.tab(...)`
  declarations, its discriminator ListValue, and the non-proxy infrastructure
  blocks; descriptor-owned fields come from a single `applyDescriptor` loop.
- `main.js` augmented to call `protocol_schema` RPC in the `load()` phase
  and populate `window.singboxUiSchemaCache` before render.
- `test_view_modules_layout.sh` extended with depends-count guard: zero
  hand-coded depends for any descriptor-owned proto allowed in either tab.

### Security (Phase D — D3)

- **Secret-reveal UX with 5-minute TTL token.** `lib/reveal.uc` token
  store (16 random bytes → 32 hex chars, persisted to
  `/var/lib/singbox-ui/reveal_token.json` mode 0600). Two new write-ACL
  RPC methods `reveal_token_grant` and `reveal_token_revoke`; existing
  read-ACL methods (`read_config`, `export_section`, `preview_config`)
  accept an optional `token` arg that bypasses scrub when valid.
- **Token is router-global, not per-session** — documented in
  `docs/secret-reveal.md` with threat model and operator guide. Audit log
  entry `event=reveal.granted user=<x>` via `lib/log.uc`.
- Frontend `Show secrets` button in action-bar with live countdown
  (`Hide secrets (M:SS)`); token lives only in `window.singboxUiRevealToken`.
  `tests/test_view_modules_layout.sh` enforces "no token in
  localStorage/sessionStorage".

### Added (Phase D — D3)

- `lib/reveal.uc` + `tests/test_reveal_uc.sh` (TDD).
- `widgets/action-bar.js` reveal button + countdown timer.
- `lib/rpc.js` `revealGrant` / `revealRevoke` / `withRevealToken(args)` helpers;
  `read_config` / `export_section` / `preview_config` callers wired.
- `docs/secret-reveal.md` operator guide.

### Added (Phase D — D4)

- `lib/plugins/registry.uc` exposes `register({name, on_generate_post})`,
  `get_all()`, `invoke_on_generate_post(config, ctx)`. Hook errors logged
  via `lib/log.uc` but never propagated.
- `lib/post_process.uc::run_pipeline` invokes registered plugins after
  implicit-direct scrubbing.
- `generate.uc` eager-loads any `/usr/share/singbox-ui/lib/plugins/*.uc`
  on boot; broken modules skipped with a `plugin.load_failed` log event.
- `tests/test_plugins_registry.sh` (TDD) covers register / invoke /
  hook-throws-don't-propagate.
- `tests/fixtures/plugins/noop.uc` — test-only plugin (NOT in install
  manifest); `tests/test_post_process_uc.sh` extended with a case
  confirming `run_pipeline` invokes the noop hook.
- `tests/test_install_manifest_fresh.sh` extended with invariant:
  production manifest contains exactly ONE file under `lib/plugins/`
  (the registry); no production plugin ships in Phase D.
- `docs/plugins.md` — plugin API contract, invariants, threat model.

### Changed (Phase D — D4)

- `lib/post_process.uc::run_pipeline` signature unchanged but now invokes
  registered plugins as a post-scrub pipeline step. Behaviour unchanged
  when no plugins are present.

---

## [v0.1.0] — 2026-06-06

### Added

**DNS**
- DNS tab in the LuCI UI with per-rule `rewrite_ttl` field and per-rule override support
- Typed DNS server/rule model (`dns_server`, `dns_rule` sections); fakeip ranges read from `dns_server`
- Default typed `dns_server`/`dns` sections shipped in uci-defaults; out-of-the-box bypass setup (tproxy + allow-domains + fakeip + Google DoH)
- Per-rule `rewrite_ttl=60` default on emitted DNS rules
- `dns.default_resolver` field exposed in UI

**Inbound**
- Inbounds tab in LuCI; `direct`-type inbound for DNS listeners (`dns_in`, 127.0.0.53:53 + hijack-dns flag)
- Field expansion: multiplex, xhttp/http transport, uTLS, VMess cipher, masquerade
- JSON import button for inbounds with protocol-validating parser
- Auto-migration from legacy `tproxy` section to typed `inbound` sections on upgrade

**Outbound**
- Field expansion: multiplex, xhttp/http transport, masquerade, `bind_interface` (UCI iface → Linux netdev)
- JSON import button for outbounds with protocol-validating parser
- Outbounds tab: GridSection table with modal+tabs, subscription expansion to selector outbound, `proxy_type=json` raw sing-box JSON support

**Cache**
- UI for storage modes (RAM / Flash / Custom path) in General tab
- `cache_file` + `store_fakeip` enabled by default (RAM storage); path resolved from storage mode
- Migration for existing `cache` sections to new storage-mode schema

**Monitoring**
- Monitoring tab: live connections and traffic via Clash API polling
- Default `clash_api` section with auto-generated secret emitted via `experimental.clash_api`
- `rpcd` `clash_request` proxy method + ACL entry

**Routing**
- Route tab; `route_default` section → `sing-box route.final`
- `hijack-dns` rule auto-emitted for `direct` inbounds flagged as `dns_listener`
- `route_action` + `block` outbound + `default_domain_resolver` support
- Source inbounds drive `hijack_dns` route rules

**Subscription**
- `fetch-subs` with Mozilla UA (fixes DDoS-Guard 200/empty-body rejection)
- Parallel curl + short-timeout boot mode
- URL-test probe URL exposed via `sub_urltest_url`
- Stale-check per section; per-section interval in `refresh.uc`
- Rule-set auto-format detection from file extension; remote + local decompile

**nftables**
- nft named sets + marking rules from `rs_*.json` caches
- Two-chain nftables (mark + tproxy); multi-interface tproxy (scalar → list, `iifname { }`)
- ucode `apply`/`remove`/`emit`/`needed` subcommands (replaces bash nftables.sh)
- Atomic ruleset replace; CIDR split into v4/v6 named sets; long ruleset names hashed to fit nft 31-byte limit

**UI / UX**
- Auto-refresh status panel after Apply/Restart actions using server time
- Rename field moved into Edit modal; per-row Rename button for outbounds/rulesets/route rules
- `detour` as outbound dropdown
- `SINGBOX_TMPDIR`/`SINGBOX_CONFIG` env vars honoured by `generate.uc`

**Build / Packaging**
- APK packaging via OpenWrt SDK host `apk` tool (skips full SDK orchestration); produces `luci-singbox-ui_<version>.apk` + `luci-i18n-singbox-ui-ru_<version>.apk`
- GitHub Actions CI: builds APK and publishes to a rolling `latest` release on every push to `main`
- `scripts/build-apk.sh`: version derivable from git tag when positional arg is omitted

**Docs**
- `docs/uci-schema.md`: full UCI schema reference covering all sections (inbound, outbound, dns, dns_server, dns_rule, ruleset, route_rule, route_default, cache, log, clash_api, subscription) with field-level coverage enforcement test
- `docs/release.md`: release procedure and SemVer rules

### Changed

- `proxy_type` field renamed to `type` across outbound UI, emit, test fixtures, and UCI helpers
- Constructor mode collapsed: `proxy_type=constructor` and protocol are now a single discriminator; `extra_json` field dropped
- `nftables.sh` moved from `/etc` to `/usr/share/singbox-ui`; bash implementation replaced by `nftables.uc`
- `fetch_subscriptions.sh` and `fetch_rulesets.sh` bash scripts replaced by `subscription.uc` ucode module
- `REFRESH_SH` env renamed to `SUBSCRIPTION_UC` in rpcd handler; `NFTABLES_SH` renamed to `NFTABLES_CMD`
- `generate.uc` collapsed to orchestration-only; sub-modules extracted into `lib/` (outbound, inbound, dns, route, ruleset, cache, log, helpers)
- main.js modularized: tabs (general, dns, inbounds, outbounds, rulesets, routing, monitoring), importers (inbound, outbound), widgets (action-bar, status-panel), and shared lib (rpc, common) extracted into separate files
- LuCI app renamed from `sing-box` to `singbox-ui`; repository restructured into `luci-singbox-ui/` subdirectory
- Mutating ubus methods moved to the `write` ACL group (security hardening)
- `rpcd` `restart` method now redirects child stderr; rpcd error message surfaced in LuCI notification

### Fixed

- ALPN/transport host field emission corrected for xhttp/http outbounds
- VMess inbound per-user security field fixed
- UCI array storage for multi-value fields (e.g. multi-interface tproxy) corrected
- FakeIP CIDR: single CIDR per family; UI/UCI/generate/nft aligned
- Subscription resolver: `set -e` propagation silently killed `uci -q get`; replaced with explicit error handling
- `uci.apply` commit flow: use `ui.changes.apply()` so LuCI apply-rollback fires correctly
- `wireTabs` `querySelectorAll` scoped to root element, not `document`
- Non-capturing regex groups (`(?:...)`) replaced — not supported in ucode on OpenWrt
- `curl -L` follow-redirects added; `curl` declared as a package dependency
- URL-decode applied to share-link query parameters
- APK ownership: root:root ownership enforced in produced packages via `unshare -r` user namespace; `verify_root_owner` belt-and-suspenders check added
- Legacy `refresh.sh` cron line removed on upgrade via uci-defaults migration
- `post-install.sh` explicitly calls `/etc/init.d/singbox-ui enable` and `start` (default_postinst silently skips because script is named `post-install.sh`, not `<pkgname>.postinst`)
- `/var/lock` and `/var/run` directories created before init service registration

### Tests

- View layout assertions for Phase A modularization
- Typed DNS model cases; inbound section coverage (shadowsocks/vless/vmess/trojan/hysteria2)
- nftables emit regression suite ported to ucode invocation
- Subscription ucode fetcher harness
- `generate.uc` smoke tests (run on VM, skip locally)
- `foreach(null)` stub fixed to iterate all sections
- `jq` and `coreutils-stat` deps dropped; assertions rewritten with ucode `json()`/`fs`
- `proxy_type→type` rename propagated to all test fixtures
- `nft -c` permission errors treated as skip rather than failure
- shellcheck CI step over all shell scripts

[Unreleased]: https://github.com/Jyn/luci-singbox/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/Jyn/luci-singbox/releases/tag/v0.1.0
