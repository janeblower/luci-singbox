# Changelog

All notable changes to this project are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
- APK packaging via OpenWrt SDK host `apk` tool (skips full SDK orchestration); produces `luci-app-singbox-ui_<version>.apk` + `luci-i18n-singbox-ui-ru_<version>.apk`
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
- LuCI app renamed from `sing-box` to `singbox-ui`; repository restructured into `luci-app-singbox-ui/` subdirectory
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

[Unreleased]: https://github.com/Jyn/luci-app-sing-box/compare/v0.1.0...HEAD
[v0.1.0]: https://github.com/Jyn/luci-app-sing-box/releases/tag/v0.1.0
