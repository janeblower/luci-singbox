# Protocol Coverage — sing-box 1.12.x

**Target sing-box version:** 1.12.x (latest of the 1.12 branch at the time of writing).
**Scope:** active protocols for the OpenWrt 24.10 client/router use-case (TProxy + outbound proxies); see `../CHANGELOG.md` for per-phase coverage history.
**Status legend:** `есть` (covered in `lib/inbound.uc` or `lib/outbound.uc`) / `нет` (planned) / `out-of-scope` (intentional, with rationale).
**Cross-references:** `docs/uci-schema.md` for UCI field names, `../CHANGELOG.md` for the implementation history.

Each row lists the **sing-box JSON path** and the **UCI field** (when one exists). Where the JSON path differs between inbound and outbound (rare), both sides are listed.

---

## Shared TLS block

Implemented by `_shared/tls.uc` (Phase E2 DSL). The two are intentionally distinct: server-side adds cert/key paths and reality handshake; client-side adds reality.public_key.

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

### tproxy (`lib/protocols/tproxy.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `tcp_fast_open`, `udp_fragment` | есть |
| `hijack_dns` (UI-only, controls nftables DNS-hijack rule) | есть |
| `interface` (UI-only list, controls nftables interface set) | есть |
| `nft_rules` (UI-only, enables nftables rule generation) | есть |

### mixed inbound (`lib/protocols/mixed.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `mixed_user` (`username:password` per entry, optional auth list) | есть |

### direct inbound (DNS listener, `lib/protocols/direct.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `network` (`tcp`/`udp`/empty) | есть |
| `override_address`, `override_port` | есть (E2) |
| `dns_listener` (UI-only flag for auto route-rule) | есть |

### shadowsocks inbound (`lib/protocols/shadowsocks.uc` — E2 DSL)
| Field | Status |
|---|---|
| `method`, `password` | есть (single-user via `server_password`) |
| `ss_user` (`name:method:password` per entry) | есть (multi-user, E2 format) |
| `users[]` (multi-user, each with `name`, `method`, `password`) | есть | — |
| `network` (`tcp`/`udp`/empty) | есть | — |
| `multiplex` | есть | — |
| `managed` (SSM API dynamic user) | out-of-scope |

### vless inbound (`lib/protocols/vless.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `server_uuid` (single-user) | есть |
| `vless_flow` (single-user `xtls-rprx-vision`) | есть |
| `inbound_user` (`list name:uuid[:flow]`, multi-user) | есть |
| `tls_enabled`, `reality_enabled`, TLS block | есть (E2 shared block) |
| `transport_type`, transport block | есть (E2 shared block) |
| `multiplex_enabled`, multiplex block | есть (E2 shared block) |

### trojan inbound (`lib/protocols/trojan.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `server_password` (single-user) | есть |
| `inbound_user` (multi-user, `name:password`) | нет (Phase 7 optional) |
| `tls_enabled`, TLS block | есть (E2 shared block) |
| `transport_type`, transport block | есть (E2 shared block) |
| `multiplex_enabled`, multiplex block | есть (E2 shared block) |
| `fallback`, `fallback_for_alpn` | out-of-scope (rare) |

### hysteria2 inbound (`lib/protocols/hysteria2.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `server_password` (single-user) | есть |
| `inbound_user` (`name:password`, multi-user) | есть |
| `tls_enabled` (forced), TLS block | есть (E2 shared block) |
| `obfs_type` (only `salamander` in 1.12) | есть |
| `obfs_password` | есть |
| `up_mbps`, `down_mbps` | есть |
| `ignore_client_bandwidth` | есть |
| `masquerade` | есть |
| `brutal_debug` | есть |

---

## Outbound protocols

### vless outbound (`lib/protocols/vless.uc` — E2 DSL)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `uuid` | `server_uuid` | n/a | есть | — |
| `flow` (`xtls-rprx-vision`) | `vless_flow` | n/a | есть | — |
| `network` | `network` | n/a | есть | E2 |
| `packet_encoding` | `packet_encoding` | n/a | есть | E2 |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | E2 |
| Shared dial fields | (see Dial fields in uci-schema.md) | n/a | есть | E2 |

### trojan outbound (`lib/protocols/trojan.uc` — E2 DSL)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | E2 |
| Shared dial fields | (see Dial fields in uci-schema.md) | n/a | есть | E2 |

### hysteria2 outbound (`lib/protocols/hysteria2.uc` — E2 DSL)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `tls` (forced) | (see Shared TLS block) | n/a | есть | E2 |
| `obfs.type` | `obfs_type` | n/a | есть | — |
| `obfs.password` | `obfs_password` | n/a | есть | — |
| `up_mbps` | `up_mbps` | n/a | есть | — |
| `down_mbps` | `down_mbps` | n/a | есть | — |
| `masquerade` | `masquerade` | n/a | есть | — |
| `brutal_debug` | `brutal_debug` | n/a | есть | — |
| `network` (`tcp`/`udp`) | `network` | n/a | есть | — |
| Shared dial fields | (see Dial fields in uci-schema.md) | n/a | есть | E2 |
| `server_ports[]`, `hop_interval`, `hop_interval_max` | — | n/a | out-of-scope (1.14+ feature) | — |

### shadowsocks outbound (`lib/protocols/shadowsocks.uc` — E2 DSL)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `method` | `shadowsocks_method` | n/a | есть | — |
| `network` | `network` | n/a | есть | E2 |
| `plugin` | `plugin` | n/a | есть | E2 |
| `plugin_opts` | `plugin_opts` | n/a | есть | E2 |
| `udp_over_tcp` | `udp_over_tcp` | n/a | есть | E2 |
| `multiplex` | `multiplex_*` | n/a | есть (shared block) | E2 |
| Shared dial fields | (see Dial fields in uci-schema.md) | n/a | есть | E2 |

> **Dropped in E2:** `tuic`, `anytls`, `ssh`, and `interface` outbound types are removed from the UI surface. Existing UCI sections are hard-deleted by migration `drop-removed-protocols-e2`.

### selector outbound (standalone)
| Field | Status |
|---|---|
| Built dynamically from subscriptions (`lib/outbound.uc:230`) | есть |
| Standalone UCI `outbound` with `type=selector` | нет | future (manual grouping) |

### urltest outbound (standalone)
Same status as selector: implemented via subscriptions, no standalone UCI form. Not in Phase B scope unless a concrete request appears.

### direct outbound
E2 DSL descriptor (`lib/protocols/direct.uc`). Replaces the legacy `type=interface` UCI outbound.
| Field | Status |
|---|---|
| `bind_interface` | есть (via shared dial block) |
| `override_address` | есть (E2) |
| `override_port` | есть (E2) |
| `proxy_protocol` | есть (E2) |
| Shared dial fields (`inet4_bind_address`, `inet6_bind_address`, `routing_mark`, etc.) | есть (via shared dial block) |

### block outbound
**Status:** нет.
**Migration note:** `block` is deprecated since sing-box 1.11.0 and **removed in 1.13.0**. Modern equivalent is rule-action `action: reject`. Phase B will **not** add a `block` outbound builder; instead, document the migration path in `docs/uci-schema.md` and ensure UI guides users to rule-actions.

### dns outbound
**Status:** нет.
**Migration note:** `dns` outbound is deprecated since sing-box 1.11.0 and **removed in 1.13.0**. Modern equivalent is rule-action `action: hijack-dns`. Same handling as `block` above.

---

## Subscription / share-link parsers

`lib/outbound.uc` `parse_proxy_url(url)` dispatcher (Phase E2: vmess removed).

| Scheme | Status | Phase |
|---|---|---|
| `vless://` | есть (`parse_vless`) | — |
| `hy2://`, `hysteria2://` | есть (`parse_hy2`) | — |
| `vmess://` (base64-JSON, v2rayN) | **dropped** (Phase E2 — VMess removed) | E2 |
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
| `isUuid` | есть (wired on `server_uuid` in vless inbound/outbound) | Phase 8 |
| `isHost` (IP or domain) | есть (wired on `server`, `tls_server_name`) | Phase 8 |
| `isAlpnNonEmpty` | есть (wired on `tls_alpn` DynamicList) | Phase 8 |
| `requiresWsPath` (transport_type=ws ⇒ path required) | есть (wired on `transport_path`) | Phase 8 |

---

## Migration notes

1. **`block`/`dns` outbound deprecation (1.11 → 1.13):** sing-box removes these outbound kinds in 1.13. The plugin already does not emit them. Explicit migration to rule-actions belongs to a later phase if user reports surface.
2. **`tls.ech.pq_signature_schemes_enabled` and `tls.ech.dynamic_record_sizing_disabled`:** deprecated in 1.12 and removed in 1.13 — never implemented, never will be.
3. **Reality `short_id` scalar (fixed in Phase 2):** `tls.reality.short_id` is a **single string** of 0-8 hex chars, not an array. Both inbound and outbound DSL descriptors emit a scalar.
4. **Phase E2 UCI key renames (`migrate_rename_e2_keys`):** `transport` → `transport_type`; `tls_ech` → `tls_ech_enabled`; `security=tls` → `tls_enabled=1`; `security=reality` → `tls_enabled=1` + `reality_enabled=1`; `utls_fingerprint` non-empty → sets `utls_enabled=1`. Run automatically on upgrade.
5. **Phase E2 protocol drop (`drop-removed-protocols-e2`):** UCI sections with `protocol ∈ {tun, vmess}` (inbound) or `type ∈ {vmess, tuic, anytls, ssh, interface}` (outbound) are hard-deleted on upgrade. Users must reconfigure any inbound/outbound that used these types.

---

*Last updated: 2026-06-09. Update this file every time a protocol descriptor or shared block gains a new field.*
