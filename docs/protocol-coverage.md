# Protocol Coverage — sing-box 1.12.x

**Target sing-box version:** 1.12.x (latest of the 1.12 branch at the time of writing).
**Scope:** see `docs/superpowers/specs/phase-b.md` § "Scope: активные протоколы".
**Status legend:** `есть` (covered in `lib/inbound.uc` or `lib/outbound.uc`) / `нет` (planned, see phase-b plan) / `out-of-scope` (intentional, with rationale).
**Cross-references:** `docs/uci-schema.md` for UCI field names, `docs/superpowers/plans/phase-b.md` for the implementation phases.

Each row lists the **sing-box JSON path** and the **UCI field** (when one exists). Where the JSON path differs between inbound and outbound (rare), both sides are listed.

---

## Shared TLS block

Implemented by `build_tls` (inbound, `lib/inbound.uc:31`) and `build_tls_client` (outbound, `lib/outbound.uc:14`). The two are intentionally distinct: server-side adds cert/key paths and reality handshake; client-side adds reality.public_key.

| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `tls.enabled` | `security != "none"` | есть | есть | — |
| `tls.server_name` | `tls_server_name` | есть | есть | — |
| `tls.certificate_path` | `tls_certificate_path` | есть | n/a (server-side) | — |
| `tls.key_path` | `tls_key_path` | есть | n/a (server-side) | — |
| `tls.alpn[]` | `tls_alpn` (list) | есть | есть | — |
| `tls.insecure` | `tls_insecure` | есть | есть | — |
| `tls.min_version` | `tls_min_version` | нет | нет | Phase 2 |
| `tls.max_version` | `tls_max_version` | нет | нет | Phase 2 |
| `tls.cipher_suites[]` | `tls_cipher_suites` | нет | нет | Phase 2 |
| `tls.utls.enabled` | `utls_fingerprint` non-empty | n/a (client only) | есть | — |
| `tls.utls.fingerprint` | `utls_fingerprint` | n/a | есть | — |
| **ECH** | | | | |
| `tls.ech.enabled` | `tls_ech` | есть | есть | — |
| `tls.ech.config[]` | `tls_ech_config` (list) | n/a (server: uses key) | есть | — |
| `tls.ech.config_path` | `tls_ech_config_path` | n/a | есть | — |
| `tls.ech.key[]` | `tls_ech_key` (list) | есть | n/a (client) | — |
| `tls.ech.key_path` | `tls_ech_key_path` | есть | n/a | — |
| `tls.ech.pq_signature_schemes_enabled` | — | **out-of-scope** | **out-of-scope** | deprecated in 1.12, removed in 1.13 |
| `tls.ech.dynamic_record_sizing_disabled` | — | **out-of-scope** | **out-of-scope** | deprecated in 1.12, removed in 1.13 |
| **Fragment (client-only, Since 1.12)** | | | | |
| `tls.fragment` (bool, flat field) | `tls_fragment` | n/a | есть | — |
| `tls.fragment_fallback_delay` | `tls_fragment_fallback_delay` | n/a | есть | — |
| `tls.record_fragment` | `tls_record_fragment` | n/a | есть | — |
| **Reality** | | | | |
| `tls.reality.enabled` | `security == "reality"` | есть | есть | — |
| `tls.reality.public_key` | `reality_public_key` | n/a (server) | есть | — |
| `tls.reality.private_key` | `reality_private_key` | есть | n/a (client) | — |
| `tls.reality.short_id` (string, 0-8 hex chars — **NOT an array**) | `reality_short_id` | есть (fix landed in Phase 2) | есть | — |
| `tls.reality.handshake.server` | `reality_handshake_server` | есть | n/a | — |
| `tls.reality.handshake.server_port` | `reality_handshake_server_port` | есть | n/a | — |
| `tls.reality.max_time_difference` | `reality_max_time_difference` | нет | n/a | Phase 2 |

---

## Inbound protocols

### tproxy (`lib/inbound.uc:110`)
| Field | Status |
|---|---|
| `tag`, `listen`, `listen_port` | есть |
| `tcp_fast_open`, `udp_fragment` | есть |
| Routing meta (`network`, `sniff_*`) | нет (Phase 2+: shared inbound fields) |

### tun (`lib/inbound.uc:114`)
| Field | Status |
|---|---|
| `interface_name`, `mtu`, `stack` | есть |
| `address[]` (inet4 + inet6) | есть |
| `auto_route`, `strict_route` | есть |
| `inet4_route_address[]`, `inet6_route_address[]` | нет (out-of-scope unless requested) |
| `endpoint_independent_nat`, `udp_timeout` | нет |

### direct (DNS listener pattern, `lib/inbound.uc:153`)
| Field | Status |
|---|---|
| `tag`, `listen`, `listen_port` | есть |
| `network` (`tcp`/`udp`/empty) | есть |
| `override_address`, `override_port` | нет (Phase 5: needed for explicit DNS hijack listener) |

### shadowsocks inbound (`lib/inbound.uc:127`)
| Field | Status |
|---|---|
| `method`, `password` | есть (single-user) |
| `users[]` (multi-user) | **нет** | Phase 5 |
| `network` (`tcp`/`udp`/empty) | нет | Phase 5 |
| `multiplex` | **нет** | Phase 5 |
| `managed` (SSM API dynamic user) | out-of-scope |

### vless inbound (`lib/inbound.uc:133`)
| Field | Status |
|---|---|
| `users[0].name`, `users[0].uuid` | есть (single-user) |
| `users[0].flow` (per-user `xtls-rprx-vision`) | есть (single-user) |
| `users[]` multi-user | **нет** | Phase 7 |
| `tls`, `transport`, `multiplex` | есть |

### vmess inbound (`lib/inbound.uc:133`)
| Field | Status | Notes |
|---|---|---|
| `users[0].name`, `users[0].uuid` | есть | single-user |
| `users[0].alter_id` | **bug**: emitted as `alter_id`; spec is `alterId` (camelCase) | Phase 7 (rename to alterId) |
| `users[]` multi-user | нет | Phase 7 |
| `tls`, `transport`, `multiplex` | есть | |

### trojan inbound (`lib/inbound.uc:133`)
| Field | Status |
|---|---|
| `users[0].name`, `users[0].password` | есть |
| `users[]` multi-user | нет (Phase 7 optional) |
| `tls`, `transport`, `multiplex` | есть |
| `fallback`, `fallback_for_alpn` | out-of-scope (rare) |

### hysteria2 inbound (`lib/inbound.uc:133`, hysteria2 branch :136)
| Field | Status |
|---|---|
| `users[0]` (single) | есть |
| `tls` (forced) | есть |
| `obfs.type` (only `salamander` in 1.12) | есть |
| `obfs.password` | есть |
| `up_mbps`, `down_mbps` | есть |
| `masquerade` | есть |
| `brutal_debug` | есть | — |
| `ignore_client_bandwidth` | есть | — |
| `users[]` multi-user | нет (Phase 7 optional, low priority — hy2 typically single auth) |

### tuic inbound
| Field | Status |
|---|---|
| All TUIC inbound fields | **нет** (entire protocol unsupported on inbound) | out-of-scope (rare in OpenWrt deployments) |

### mixed / socks / http inbound
Not present as distinct UCI types. The spec lists them under "scope" but in practice they map to direct/vless/etc. — flagging as **out-of-scope** unless a concrete request appears.

---

## Outbound protocols

### vless outbound (`build_constructor_for`, `lib/outbound.uc:74`)
| Field | Status |
|---|---|
| `server`, `server_port`, `uuid` | есть |
| `flow` (`xtls-rprx-vision`) | есть |
| `tls`, `transport`, `multiplex` | есть |
| `network` (`tcp`/`udp`) | нет (Phase 4 add as shared outbound field) |
| `packet_encoding` | out-of-scope |

### vmess outbound (`lib/outbound.uc:82`)
| Field | Status |
|---|---|
| `server`, `server_port`, `uuid` | есть |
| `alter_id` | есть (JSON key matches doc: `alter_id`) |
| `security` | есть |
| `tls`, `transport`, `multiplex` | есть |
| `network` | нет |
| `global_padding`, `authenticated_length` | out-of-scope |

### trojan outbound (`lib/outbound.uc:77`)
| Field | Status |
|---|---|
| `server`, `server_port`, `password` | есть |
| `tls`, `transport`, `multiplex` | есть |
| `network` | нет |

### hysteria2 outbound (`lib/outbound.uc:88`)
| Field | Status |
|---|---|
| `server`, `server_port`, `password` | есть |
| `tls` (forced) | есть |
| `obfs.type`, `obfs.password` | есть |
| `up_mbps`, `down_mbps` | есть |
| `masquerade` (server-side concept; ignored in outbound) | есть as field, but no-op |
| `brutal_debug` | есть | — |
| `network` (`tcp`/`udp`) | есть | — |
| `server_ports[]`, `hop_interval`, `hop_interval_max` | out-of-scope (multi-port hop is 1.14+ feature) |

### shadowsocks outbound (`lib/outbound.uc:77,86`)
| Field | Status |
|---|---|
| `server`, `server_port`, `password`, `method` | есть |
| `network` | нет |
| `multiplex` | нет (currently only enabled for vless/vmess/trojan in `build_constructor_for`:101) |
| `plugin`, `plugin_opts` | out-of-scope (legacy SIP022 plugin chaining) |

### tuic outbound (`lib/outbound.uc`, tuic branch)
| Field | Status |
|---|---|
| `server`, `server_port`, `uuid`, `password` | есть | — |
| `congestion_control` | есть | — |
| `udp_relay_mode` | есть | — |
| `udp_over_stream` (mutually exclusive with `udp_relay_mode`) | есть | — |
| `zero_rtt_handshake` | есть | — |
| `heartbeat` | есть | — |
| `network` (`tcp`/`udp`) | есть | — |
| `tls` (required) | есть | — |

### anytls outbound (Since 1.12.0)
| Field | Status |
|---|---|
| `server`, `server_port`, `password` | **нет** | Phase 6 |
| `idle_session_check_interval` (default `30s`) | нет | Phase 6 |
| `idle_session_timeout` (default `30s`) | нет | Phase 6 |
| `min_idle_session` (default `0`) | нет | Phase 6 |
| `tls` (required) | нет | Phase 6 |
| transport / multiplex | **out-of-scope** (AnyTLS has no v2ray-transport) |

### interface outbound (`lib/outbound.uc:202`)
Maps to sing-box `direct` with `bind_interface`. Status: **есть**, no further fields planned.

### selector outbound (standalone)
| Field | Status |
|---|---|
| Built dynamically from subscriptions (`lib/outbound.uc:230`) | есть |
| Standalone UCI `outbound` with `type=selector` | нет | future (manual grouping) |

### urltest outbound (standalone)
Same status as selector: implemented via subscriptions, no standalone UCI form. Not in Phase B scope unless a concrete request appears.

### direct outbound
| Field | Status |
|---|---|
| `bind_interface` | есть (via interface kind) |
| Standalone `type=direct` (no bind) | нет (low priority — most users want interface bind) |

### block outbound
**Status:** нет.
**Migration note:** `block` is deprecated since sing-box 1.11.0 and **removed in 1.13.0**. Modern equivalent is rule-action `action: reject`. Phase B will **not** add a `block` outbound builder; instead, document the migration path in `docs/uci-schema.md` and ensure UI guides users to rule-actions.

### dns outbound
**Status:** нет.
**Migration note:** `dns` outbound is deprecated since sing-box 1.11.0 and **removed in 1.13.0**. Modern equivalent is rule-action `action: hijack-dns`. Same handling as `block` above.

---

## Subscription / share-link parsers

`lib/outbound.uc:166` `parse_proxy_url(url)` dispatcher.

| Scheme | Status | Phase |
|---|---|---|
| `vless://` | есть (`parse_vless`, :129) | — |
| `hy2://`, `hysteria2://` | есть (`parse_hy2`, :150) | — |
| `vmess://` (base64-JSON, v2rayN) | нет | Phase 10 |
| `ss://` (plain + base64) | нет | Phase 10 |
| `trojan://` | нет | Phase 10 |
| `tuic://` | out-of-scope (no canonical share-link spec) |
| `anytls://` | out-of-scope (no canonical share-link spec yet) |

---

## RPC methods

`root/usr/libexec/rpcd/singbox-ui`, current set: `generate`, `nftables`, `restart`, `refresh`, `status`, `read_config`, `clash_request`.

| Method | Status | Phase |
|---|---|---|
| `export_section(kind, name)` | нет | Phase 9 (B5) |
| `preview_config` (dry-run) | нет | Phase 11 (B8) |

---

## UI form validation

| Validator | Status | Phase |
|---|---|---|
| `isPort` (1-65535) | нет (no `lib/validators.js` exists) | Phase 8 (B6) |
| `isUuid` | нет | Phase 8 |
| `isHost` (IP or domain) | нет | Phase 8 |
| `isAlpnNonEmpty` | нет | Phase 8 |
| `requiresWsPath` (transport=ws ⇒ path required) | нет | Phase 8 |
| `softWarnCongestion` (warn-not-block for unknown congestion_control) | нет | Phase 8 |

---

## Migration notes

1. **`block`/`dns` outbound deprecation (1.11 → 1.13):** sing-box removes these outbound kinds in 1.13. The plugin already does not emit them. Phase B documents the migration path; explicit migration to rule-actions belongs to a later phase if user reports surface.
2. **`tls.ech.pq_signature_schemes_enabled` and `tls.ech.dynamic_record_sizing_disabled`:** deprecated in 1.12 and removed in 1.13 — never implemented, never will be.
3. **Reality `short_id` array bug:** `lib/inbound.uc:48` emits `r.short_id = [ s.reality_short_id ]` (an array). Per sing-box docs for 1.12.x, `tls.reality.short_id` is a **single string** of 0-8 hex chars. The outbound side (`lib/outbound.uc:28`) is already correct. Phase 2 fixes the inbound emission; a UCI migration is not required (the wire field changes shape, but the UCI schema already stores a single string).
4. **VMess `alterId` casing:** `lib/inbound.uc:24` and `lib/outbound.uc:83` emit `alter_id` (snake_case). The sing-box 1.12 schema accepts both, but the documented canonical name is `alterId` for vmess users. Phase 7 aligns inbound emission with the documented camelCase for the users array; outbound legacy field can stay (single-user trim).
5. **AnyTLS new in 1.12:** Phase 6 adds full coverage; UCI section `outbound` gets new fields `idle_session_check_interval`, `idle_session_timeout`, `min_idle_session`.

---

*Last updated: 2026-06-06. Update this file every time `lib/inbound.uc` or `lib/outbound.uc` gains a new field or protocol case.*
