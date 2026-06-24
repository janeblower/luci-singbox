# Protocol Coverage — sing-box 1.12–1.14

**Target sing-box version:** 1.12+ baseline, with per-protocol version gating up
to 1.14 (e.g. `anytls` since 1.12, `naive` outbound since 1.13, `cloudflared`
inbound since 1.14 — gated by each descriptor's `min_version`).
**Scope:** active protocols for the OpenWrt 25.12 client/router use-case (TProxy + outbound proxies); see `../CHANGELOG.md` for per-phase coverage history.
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

### tproxy (`lib/builder/protocols/tproxy.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `tcp_fast_open`, `udp_fragment` | есть |
| `hijack_dns` (UI-only, controls nftables DNS-hijack rule) | есть |
| `interface` (UI-only list, controls nftables interface set) | есть |
| `nft_rules` (UI-only, enables nftables rule generation) | есть |

### mixed inbound (`lib/builder/protocols/mixed.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `mixed_user` (`username:password` per entry, optional auth list) | есть |

### direct inbound (DNS listener, `lib/builder/protocols/direct.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `network` (`tcp`/`udp`/empty) | есть |
| `override_address`, `override_port` | есть (E2) |
| `dns_listener` (UI-only flag for auto route-rule) | есть |

### shadowsocks inbound (`lib/builder/protocols/shadowsocks.uc` — E2 DSL)
| Field | Status |
|---|---|
| `method`, `password` | есть (single-user via `server_password`) |
| `ss_user` (`name:method:password` per entry) | есть (multi-user, E2 format) |
| `users[]` (multi-user, each with `name`, `method`, `password`) | есть | — |
| `network` (`tcp`/`udp`/empty) | есть | — |
| `multiplex` | есть | — |
| `managed` (SSM API dynamic user) | out-of-scope |

### vless inbound (`lib/builder/protocols/vless.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `server_uuid` (single-user) | есть |
| `vless_flow` (single-user `xtls-rprx-vision`) | есть |
| `inbound_user` (`list name:uuid[:flow]`, multi-user) | есть |
| `tls_enabled`, `reality_enabled`, TLS block | есть (E2 shared block) |
| `transport_type`, transport block | есть (E2 shared block) |
| `multiplex_enabled`, multiplex block | есть (E2 shared block) |

### trojan inbound (`lib/builder/protocols/trojan.uc` — E2 DSL)
| Field | Status |
|---|---|
| `listen`, `listen_port` | есть |
| `server_password` (single-user) | есть |
| `inbound_user` (multi-user, `name:password`) | нет (Phase 7 optional) |
| `tls_enabled`, TLS block | есть (E2 shared block) |
| `transport_type`, transport block | есть (E2 shared block) |
| `multiplex_enabled`, multiplex block | есть (E2 shared block) |
| `fallback`, `fallback_for_alpn` | out-of-scope (rare) |

### hysteria2 inbound (`lib/builder/protocols/hysteria2.uc` — E2 DSL)
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

### redirect inbound (`lib/builder/protocols/redirect.uc` — protocol matrix)
Linux/macOS REDIRECT-target inbound. No protocol options beyond the listen base.
| Field | Status |
|---|---|
| `listen` (default `::`) | есть |
| `listen_port` (default `7894`) | есть |

### cloudflared inbound (`lib/builder/protocols/cloudflared.uc` — hand `emit()`, Since 1.14)
Cloudflare Tunnel inbound. The only inbound with **no** `listen`/`listen_port`
(built via the `emit()` escape-hatch, not the filler listen-base), gated by
`min_version: "1.14.0"`. `control_dialer`/`tunnel_dialer` nested dial objects are out-of-scope.
| Field | Status |
|---|---|
| `token` (required, secret) | есть |
| `ha_connections` | есть (advanced) |
| `protocol` (`cf_protocol`: `http2`/`quic`) | есть (advanced) |
| `post_quantum` | есть (advanced) |
| `edge_ip_version` (`4`/`6`) | есть (advanced) |
| `datagram_version` | есть (advanced) |
| `grace_period` | есть (advanced) |
| `region` | есть (advanced) |

---

## Outbound protocols

### vless outbound (`lib/builder/protocols/vless.uc` — E2 DSL)
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

### trojan outbound (`lib/builder/protocols/trojan.uc` — E2 DSL)
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| `server` | `server` | n/a | есть | — |
| `server_port` | `server_port` | n/a | есть | — |
| `password` | `server_password` | n/a | есть | — |
| `tls`, `transport`, `multiplex` | (see Shared TLS block) | n/a | есть | E2 |
| Shared dial fields | (see Dial fields in uci-schema.md) | n/a | есть | E2 |

### hysteria2 outbound (`lib/builder/protocols/hysteria2.uc` — E2 DSL)
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

### shadowsocks outbound (`lib/builder/protocols/shadowsocks.uc` — E2 DSL)
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

> **Dropped in E2 / Re-added in protocol matrix:** `tuic`, `anytls`, `ssh`, `vmess` outbound types were removed in E2 but re-added in the expanded protocol matrix (Task 6.1). The E2 hard-delete migration ran once on existing pre-matrix installs; new installs configure them from scratch.

### socks outbound (`lib/builder/protocols/socks.uc` — protocol matrix)
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `version` | `socks_version` | есть | matrix |
| `username` | `username` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `network` | `network` | есть | matrix |
| `udp_over_tcp` | `udp_over_tcp` | есть | matrix |

### http outbound (`lib/builder/protocols/http.uc` — protocol matrix)
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `username` | `username` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `path` | `http_path` | есть | matrix |

### vmess outbound (`lib/builder/protocols/vmess.uc` — protocol matrix)
Re-added after E2 removal. sing-box 1.12 VMess outbound.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `uuid` | `server_uuid` | есть | matrix |
| `security` | `vmess_security` | есть | matrix |
| `alter_id` | `alter_id` | есть | matrix |
| `global_padding` | `global_padding` | есть | matrix |
| `authenticated_length` | `authenticated_length` | есть | matrix |
| `network` | `network` | есть | matrix |
| `packet_encoding` | `packet_encoding` | есть | matrix |

### hysteria outbound (`lib/builder/protocols/hysteria.uc` — protocol matrix)
Legacy Hysteria v1 (distinct from hysteria2).
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `server_ports` | `server_ports` | есть | matrix |
| `hop_interval` | `hop_interval` | есть | matrix |
| `up_mbps` | `up_mbps` | есть | matrix |
| `down_mbps` | `down_mbps` | есть | matrix |
| `auth_str` | `hysteria_auth_str` | есть | matrix |
| `obfs` | `obfs` | есть | matrix |
| `network` | `network` | есть | matrix |
| `recv_window_conn` | `recv_window_conn` | есть | matrix |
| `recv_window` | `recv_window` | есть | matrix |
| `disable_mtu_discovery` | `disable_mtu_discovery` | есть | matrix |

### tuic outbound (`lib/builder/protocols/tuic.uc` — protocol matrix)
Re-added after E2 removal. sing-box 1.12 TUIC v5.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `uuid` | `server_uuid` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `congestion_control` | `congestion_control` | есть | matrix |
| `udp_relay_mode` | `udp_relay_mode` | есть | matrix |
| `udp_over_stream` | `udp_over_stream` | есть | matrix |
| `zero_rtt_handshake` | `zero_rtt_handshake` | есть | matrix |
| `heartbeat` | `heartbeat` | есть | matrix |
| `network` | `network` | есть | matrix |

### anytls outbound (`lib/builder/protocols/anytls.uc` — protocol matrix)
Re-added after E2 removal.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `idle_session_check_interval` | `idle_session_check_interval` | есть | matrix |
| `idle_session_timeout` | `idle_session_timeout` | есть | matrix |
| `min_idle_session` | `min_idle_session` | есть | matrix |

### shadowtls outbound (`lib/builder/protocols/shadowtls.uc` — protocol matrix)
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `version` | `shadowtls_version` | есть | matrix |
| `password` | `server_password` | есть | matrix |

### ssh outbound (`lib/builder/protocols/ssh.uc` — protocol matrix)
Re-added after E2 removal.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `user` | `ssh_user` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `private_key` | `private_key` | есть | matrix |
| `private_key_path` | `private_key_path` | есть | matrix |
| `private_key_passphrase` | `private_key_passphrase` | есть | matrix |
| `host_key[]` | `host_key` | есть | matrix |
| `host_key_algorithms[]` | `host_key_algorithms` | есть | matrix |
| `client_version` | `client_version` | есть | matrix |
| `cipher[]` | `ssh_cipher` | есть | matrix |
| `mac[]` | `ssh_mac` | есть | matrix |
| `kex_algorithm[]` | `ssh_kex_algorithm` | есть | matrix |

### naive outbound (`lib/builder/protocols/naive.uc` — protocol matrix)
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `server` | `server` | есть | matrix |
| `server_port` | `server_port` | есть | matrix |
| `username` | `username` | есть | matrix |
| `password` | `server_password` | есть | matrix |
| `network` | `network` | есть | matrix |
| `insecure_concurrency` | `insecure_concurrency` | есть | matrix |
| `quic_congestion_control` | `quic_congestion_control` | есть | matrix |

### selector outbound (`lib/builder/protocols/groups.uc` — protocol matrix)
Standalone UCI `outbound` with `type=selector`. Selects one outbound from a group, with optional default and interrupt behaviour.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `outbounds[]` | `group_outbounds` | есть | matrix |
| `default` | `group_default` | есть | matrix |
| `interrupt_exist_connections` | `interrupt_exist_connections` | есть | matrix |

### urltest outbound (`lib/builder/protocols/groups.uc` — protocol matrix)
Automatically selects the best outbound by latency test.
| sing-box JSON | UCI | Outbound | Phase |
|---|---|---|---|
| `outbounds[]` | `group_outbounds` | есть | matrix |
| `url` | `group_url` | есть | matrix |
| `interval` | `group_interval` | есть | matrix |
| `tolerance` | `group_tolerance` | есть | matrix |
| `idle_timeout` | `group_idle_timeout` | есть | matrix |
| `interrupt_exist_connections` | `interrupt_exist_connections` | есть | matrix |

### direct outbound
E2 DSL descriptor (`lib/builder/protocols/direct.uc`). Replaces the legacy `type=interface` UCI outbound.
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

### json outbound
Verbatim passthrough type (Task 4): emits the UCI `raw_json` field as a literal
sing-box outbound JSON object. No structured descriptor fields beyond the raw
payload — the registry exposes exactly one field.
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| (verbatim object) | `raw_json` | есть | есть | Task 4 |

### sharelink outbound
Verbatim passthrough type (Task 4): stores a `raw_link` share-link URL that is
expanded to a full outbound at generation time. No structured descriptor fields
beyond the raw payload.
| sing-box JSON | UCI | Inbound | Outbound | Phase |
|---|---|---|---|---|
| (expanded from share-link URL) | `raw_link` | есть | есть | Task 4 |

---

## AWG-WARP plugin (`luci-app-singbox-plugin-awg-warp`)

The AWG-WARP plugin ships as a **separate 5th package** (noarch) with its own
install path at `luci-app-singbox-plugin-awg-warp/`. It adds a single contributed
outbound type `awg_warp` via the plugin registry (`lib/plugins/registry.uc`).

**Architecture summary:**
- `lib/plugins/awg_warp/descriptor.uc` — registers the outbound type; `emit()` escape-hatch produces `{type:direct, tag, bind_interface:<iface>}` (no listen base).
- `lib/plugins/awg_warp/iface.uc` — computes the per-outbound interface name (`awg<N>`, max 12 chars); all UCI-derived names/CIDR sanitized.
- `lib/plugins/awg_warp/reconcile.uc` — native ephemeral interface lifecycle via `ip`/`awg`; never writes `/etc/config/network`. `setconf` split avoids cleartext key in process args.
- `lib/plugins/awg_warp/warp.uc` — WARP registration (`auto` + `paste` modes); WARP-safe AWG keygen forces `S=0`/`H=1234` reserved bytes.
- `lib/plugins/awg_warp/nft.uc` — masquerade fragment: `table ip singbox_ui_awg_nat` (v4) + `table ip6 singbox_ui_awg_nat6` (v6 when `ipv6_enabled`); no double-NAT; all interface names double-sanitized.
- `lib/plugins/awg_warp/awggen.uc` — AWG parameter generation; `target=warp` forces S=0/H=1234.
- `lib/plugins/awg_warp/init.uc` — rpcd method dispatcher (`awg_status`, `awg_install`, `warp_register`, `awg_generate`); self-provision adds amneziawg feed key + `apk add ip-full kmod-amneziawg amneziawg-tools`.
- `htdocs/.../plugins/awg_warp/tab.js` — plugin frontend tab (own i18n domain `luci-singbox-plugin-awg-warp`).

### awg_warp outbound

Descriptor: `lib/plugins/awg_warp/descriptor.uc`. sing-box type: **`direct`** with `bind_interface`. WARP credentials + AWG obfuscation params are UCI-only; only `bind_interface` reaches the generated sing-box JSON.

| sing-box JSON | UCI | Status | Notes |
|---|---|---|---|
| `type` | — | есть | always `"direct"` |
| `tag` | `outbound` section name | есть | |
| `bind_interface` | derived via `iface_name()` | есть | ephemeral `awgN` iface |
| — | `awg_mimic` | есть (UCI-only) | outer UDP camouflage protocol |
| — | `ipv6_enabled` | есть (UCI-only) | enables NAT66 masquerade |
| — | `mtu_override` | есть (UCI-only) | empty = WAN MTU − 80 |
| — | `warp_public_key` | есть (UCI-only, rpcd-written) | WARP endpoint public key |
| — | `warp_private_key` | есть (UCI-only, rpcd-written) | local private key |
| — | `warp_address_v4` | есть (UCI-only, rpcd-written) | WARP-assigned IPv4/CIDR |
| — | `warp_address_v6` | есть (UCI-only, rpcd-written) | WARP-assigned IPv6/CIDR |
| — | `warp_endpoint` | есть (UCI-only, rpcd-written) | WARP UDP endpoint |
| — | `awg_jc` / `awg_jmin` / `awg_jmax` | есть (UCI-only, rpcd-written) | AWG junk parameters |
| — | `awg_i1` | есть (UCI-only, rpcd-written) | AWG init packet magic |

**Self-provision pattern:** Plugins tab → "Install AWG + ip-full" button calls `awg_install` rpcd method, which adds the amneziawg OpenWrt feed key and runs `apk add ip-full kmod-amneziawg amneziawg-tools`. Runtime kmod is NOT a package dependency — self-provisioned to avoid arch-specific dep resolution at LuCI install time.

**WARP-safe keygen:** `awggen.uc` `generate(target="warp")` always sets `S=0` and `H=1234` (Cloudflare's reserved-byte values); `target="selfhosted"` generates random obfuscation. Mixing is an error caught by `validate_selfhosted`.

**Addrlabel / MTU:** reconciler adds per-interface IPv6 addrlabel; MTU = WAN MTU − 80 (default, overridable via `mtu_override`).

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

*Last updated: 2026-06-25. Update this file every time a protocol descriptor or shared block gains a new field.*
