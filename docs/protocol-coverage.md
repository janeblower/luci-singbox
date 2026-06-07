# Protocol Coverage — sing-box 1.12.x

**Target sing-box version:** 1.12.x (latest of the 1.12 branch at the time of writing).
**Scope:** active protocols for the OpenWrt 24.10 client/router use-case (TProxy + outbound proxies); see `../CHANGELOG.md` for per-phase coverage history.
**Status legend:** `есть` (covered in `lib/inbound.uc` or `lib/outbound.uc`) / `нет` (planned) / `out-of-scope` (intentional, with rationale).
**Cross-references:** `docs/uci-schema.md` for UCI field names, `../CHANGELOG.md` for the implementation history.

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
| `users[]` (multi-user) | есть | — |
| `network` (`tcp`/`udp`/empty) | есть | — |
| `multiplex` | есть | — |
| `managed` (SSM API dynamic user) | out-of-scope |

### vless inbound (`lib/inbound.uc:133`)
| Field | Status |
|---|---|
| `users[0].name`, `users[0].uuid` | есть (single-user) |
| `users[0].flow` (per-user `xtls-rprx-vision`) | есть (single-user) |
| `users[]` multi-user | есть (Phase 7: `list inbound_user 'name:uuid[:flow]'`) |
| `tls`, `transport`, `multiplex` | есть |

### vmess inbound (`lib/inbound.uc:133`)
| Field | Status | Notes |
|---|---|---|
| `users[0].name`, `users[0].uuid` | есть | single-user |
| `users[0].alterId` | есть | emitted as `alterId` (camelCase, corrected in Phase 7) |
| `users[]` multi-user | есть | Phase 7: `list inbound_user 'name:uuid[:alterId]'` |
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
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `uuid` | `server_uuid` | n/a | есть | — |
| `flow` (`xtls-rprx-vision`) | `vless_flow` | n/a | есть | — |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | — |
| `network` (`tcp`/`udp`) | — | n/a | нет (Phase 4) | — |
| `packet_encoding` | — | n/a | out-of-scope | — |

### vmess outbound (`lib/outbound.uc:82`)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `uuid` | `server_uuid` | n/a | есть | — |
| `alter_id` | `vmess_alter_id` | n/a | есть | — |
| `security` | `vmess_security` | n/a | есть | — |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | — |
| `network` | — | n/a | нет | — |
| `global_padding`, `authenticated_length` | — | n/a | out-of-scope | — |

### trojan outbound (`lib/outbound.uc:77`)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | — |
| `network` | — | n/a | нет | — |

### hysteria2 outbound (`lib/outbound.uc:88`)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `tls` (forced) | (see Shared TLS block) | n/a | есть | — |
| `obfs.type` | `hysteria2_obfs_type` | n/a | есть | — |
| `obfs.password` | `hysteria2_obfs_password` | n/a | есть | — |
| `up_mbps` | `up_mbps` | n/a | есть | — |
| `down_mbps` | `down_mbps` | n/a | есть | — |
| `masquerade` (server-side concept; ignored in outbound) | `hysteria2_masquerade` | n/a | есть (no-op) | — |
| `brutal_debug` | `brutal_debug` | n/a | есть | — |
| `network` (`tcp`/`udp`) | `network` | n/a | есть | — |
| `server_ports[]`, `hop_interval`, `hop_interval_max` | — | n/a | out-of-scope (1.14+ feature) | — |

### shadowsocks outbound (`lib/outbound.uc:77,86`)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `method` | `shadowsocks_method` | n/a | есть | — |
| `network` | — | n/a | нет | — |
| `multiplex` | — | n/a | нет (vless/vmess/trojan only) | — |
| `plugin`, `plugin_opts` | — | n/a | out-of-scope (legacy SIP022) | — |

### tuic outbound (`lib/outbound.uc`, tuic branch)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `uuid` | `server_uuid` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `congestion_control` | `tuic_congestion` | n/a | есть | — |
| `udp_relay_mode` | `tuic_udp_relay_mode` | n/a | есть | — |
| `udp_over_stream` (mutually exclusive with `udp_relay_mode`) | `tuic_udp_over_stream` | n/a | есть | — |
| `zero_rtt_handshake` | `tuic_zero_rtt` | n/a | есть | — |
| `heartbeat` | `tuic_heartbeat` | n/a | есть | — |
| `network` (`tcp`/`udp`) | `network` | n/a | есть | — |
| `tls` (required) | (see Shared TLS block) | n/a | есть | — |

### anytls outbound (`lib/outbound.uc`, anytls branch — Since 1.12.0)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `idle_session_check_interval` (default `30s`) | `anytls_idle_check_interval` | n/a | есть | — |
| `idle_session_timeout` (default `30s`) | `anytls_idle_timeout` | n/a | есть | — |
| `min_idle_session` (default `0`) | `anytls_min_idle_session` | n/a | есть | — |
| `tls` (required) | (see Shared TLS block) | n/a | есть | — |
| transport / multiplex | — | n/a | out-of-scope (AnyTLS has no v2ray-transport) | — |

### ssh outbound (`lib/protocols/ssh.uc` — Since 1.12.0)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `user` | `user` | n/a | есть | — |
| `password` | `password` | n/a | есть | — |
| `private_key_path` | `private_key_path` | n/a | есть | — |
| `host_key[]` | `host_key` (list) | n/a | есть | — |

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
| `vmess://` (base64-JSON, v2rayN) | есть (`parse_vmess`) | — |
| `ss://` (plain + base64) | есть (`parse_ss`) | — |
| `trojan://` | есть (`parse_trojan`) | — |
| `tuic://` | out-of-scope (no canonical share-link spec) |
| `anytls://` | out-of-scope (no canonical share-link spec yet) |

---

## RPC methods

`root/usr/libexec/rpcd/singbox-ui`, current set: `generate`, `nftables`, `restart`, `refresh`, `status`, `read_config`, `clash_request`, `export_section`, `preview_config`.

| Method | Status | Phase |
|---|---|---|
| `export_section(kind, name)` | есть (rpcd handler + `export_section.uc` helper; UI "Export JSON" button per row, modal with Copy) | Phase 9 (B5) |
| `preview_config` (dry-run) | есть (rpcd handler runs `generate.uc` with `SINGBOX_CONFIG` pointed at a per-call tmpfile; UI "Preview config" button in the action bar, modal with Copy) | Phase 11 (B8) |

---

## UI form validation

| Validator | Status | Phase |
|---|---|---|
| `isPort` (1-65535) | есть (`lib/validators.js`, wired on `listen_port` / `server_port`) | Phase 8 (B6) |
| `isUuid` | есть (wired on `server_uuid` in inbounds/outbounds) | Phase 8 |
| `isHost` (IP or domain) | есть (wired on `server`, `tls_server_name`) | Phase 8 |
| `isAlpnNonEmpty` | есть (wired on `tls_alpn` DynamicList) | Phase 8 |
| `requiresWsPath` (transport=ws ⇒ path required) | есть (wired on `transport_path`) | Phase 8 |
| `softWarnCongestion` (warn-not-block for unknown congestion_control) | есть (wired on `tuic_congestion`) | Phase 8 |

---

## Migration notes

1. **`block`/`dns` outbound deprecation (1.11 → 1.13):** sing-box removes these outbound kinds in 1.13. The plugin already does not emit them. Phase B documents the migration path; explicit migration to rule-actions belongs to a later phase if user reports surface.
2. **`tls.ech.pq_signature_schemes_enabled` and `tls.ech.dynamic_record_sizing_disabled`:** deprecated in 1.12 and removed in 1.13 — never implemented, never will be.
3. **Reality `short_id` array bug:** `lib/inbound.uc:48` emits `r.short_id = [ s.reality_short_id ]` (an array). Per sing-box docs for 1.12.x, `tls.reality.short_id` is a **single string** of 0-8 hex chars. The outbound side (`lib/outbound.uc:28`) is already correct. Phase 2 fixes the inbound emission; a UCI migration is not required (the wire field changes shape, but the UCI schema already stores a single string).
4. **VMess `alterId` casing:** `lib/inbound.uc:24` and `lib/outbound.uc:83` emit `alter_id` (snake_case). The sing-box 1.12 schema accepts both, but the documented canonical name is `alterId` for vmess users. Phase 7 aligns inbound emission with the documented camelCase for the users array; outbound legacy field can stay (single-user trim).
5. **AnyTLS new in 1.12:** Phase 6 adds full coverage; UCI section `outbound` gets new fields `idle_session_check_interval`, `idle_session_timeout`, `min_idle_session`.

---

*Last updated: 2026-06-06. Update this file every time `lib/inbound.uc` or `lib/outbound.uc` gains a new field or protocol case.*
