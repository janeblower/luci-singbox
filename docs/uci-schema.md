# UCI Schema — `singbox-ui`

Source of truth: this file. Everything read by `lib/*.uc` or written by the LuCI UI should be reflected here.

## Sections

- [`inbound`](#inbound)
- [`outbound`](#outbound)
- [`ruleset`](#ruleset)
- [`route_rule`](#route_rule)
- [`route_default`](#route_default)
- [`dns`](#dns)
- [`dns_server`](#dns_server)
- [`dns_rule`](#dns_rule)
- [`cache`](#cache)
- [`log`](#log)
- [`clash_api`](#clash_api)
- [`subscription`](#subscription)

## Migrations

See `luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui` for the source of truth on schema migrations applied on upgrade.

(Detailed migration log will be populated in Task 23.)

---

## `inbound`

UCI section type: `inbound`. Describes an incoming listener for sing-box.

Backend: `lib/inbound.uc` — `build_one(s)` reads every field listed here.
UI write: `tabs/inbounds.js` — `buildInboundsMap()`.

### Core fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections (`enabled=0`) are skipped by `build_inbounds`. |
| `protocol` | enum | `direct`, `tproxy`, `tun`, `shadowsocks`, `vless`, `vmess`, `trojan`, `hysteria2` | yes | — | Selects the protocol branch in `build_one`. Defaults to `tproxy` if absent. Legacy field `mode` is silently ignored. |
| `listen` | string | IP address or `::` | no | all except `tun` | Bind address. Defaults to `::` if empty. |
| `listen_port` | integer | valid port | yes (except tun) | all except `tun` | Listen port. Missing/zero causes the section to be skipped with a warning. |

### `direct` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `network` | enum | `""` (both), `tcp`, `udp` | no | `protocol=direct` | Restricts accepted network. Empty or any other value omits `network` from output (sing-box treats absence as tcp+udp). |
| `dns_listener` | bool | `0`/`1` | no | `protocol=direct` | UI-only: when set, the UI auto-emits a hijack-dns route rule for this inbound. **Not read by `inbound.uc`**. |

### `tproxy` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `tcp_fast_open` | bool | `0`/`1` | no | `protocol=tproxy` | Enables TCP Fast Open on the listener. |
| `udp_fragment` | bool | `0`/`1` | no | `protocol=tproxy` | Enables UDP fragment reassembly. |
| `hijack_dns` | bool | `0`/`1` | no | `protocol=tproxy` | UI-only: controls whether an nftables DNS-hijack rule is installed. **Not read by `inbound.uc`**. |
| `interface` | string (list) | device names | no | `protocol=tproxy` | UI-only: selects network interfaces for nftables rules. **Not read by `inbound.uc`**. |
| `nft_rules` | bool | `0`/`1` | no | `protocol=tproxy` or `tun` | UI-only: controls nftables rule generation. **Not read by `inbound.uc`**. |

### `tun` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `interface_name` | string | e.g. `singbox-tun` | no | `protocol=tun` | TUN device name. Defaults to `singbox-tun` if absent. |
| `inet4_address` | string | CIDR4 | no | `protocol=tun` | IPv4 address/prefix for the TUN interface, e.g. `172.19.0.1/30`. |
| `inet6_address` | string | CIDR6 | no | `protocol=tun` | IPv6 address/prefix for the TUN interface. |
| `mtu` | integer | e.g. `9000` | no | `protocol=tun` | MTU of the TUN device. |
| `auto_route` | bool | `0`/`1` | no | `protocol=tun` | Enables automatic route injection for the TUN device. |
| `strict_route` | bool | `0`/`1` | no | `protocol=tun` | Enables strict routing (requires `auto_route=1`). |
| `stack` | enum | `system`, `gvisor`, `mixed` | no | `protocol=tun` | Network stack implementation. |
| `nft_rules` | bool | `0`/`1` | no | `protocol=tproxy` or `tun` | UI-only: controls nftables rule generation. **Not read by `inbound.uc`**. |

### `shadowsocks` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `shadowsocks_method` | enum | e.g. `aes-256-gcm`, `chacha20-ietf-poly1305` | yes | `protocol=shadowsocks` | Encryption cipher. |
| `server_password` | string | — | yes | `protocol=shadowsocks` | Shared password. |

### User credential fields (vless / vmess / trojan)

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_uuid` | string | UUID | yes | `protocol=vless` or `vmess` | UUID for the single user entry. |
| `server_password` | string | — | yes | `protocol=trojan` | Password for the single user entry (also used by `hysteria2`). |
| `vless_flow` | enum | `none`, `xtls-rprx-vision` | no | `protocol=vless` | VLESS flow control. Omitted when `none`. |
| `vmess_alter_id` | integer | `0`+ | no | `protocol=vmess` | VMess alter ID. |
| `vmess_security` | enum | `auto`, `none`, `aes-128-gcm`, `chacha20-poly1305` | no | `protocol=vmess` | UI-only: cipher hint written to UCI. **Not read by `inbound.uc`** (inbound VMess does not accept a per-user security field; cipher is client-selected). |

### `hysteria2` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_password` | string | — | yes | `protocol=hysteria2` | Authentication password. |
| `up_mbps` | integer | Mbps | no | `protocol=hysteria2` | Upload bandwidth limit. |
| `down_mbps` | integer | Mbps | no | `protocol=hysteria2` | Download bandwidth limit. |
| `hysteria2_obfs_type` | enum | `none`, `salamander` | no | `protocol=hysteria2` | Obfuscation type. Omitted when `none`. |
| `hysteria2_obfs_password` | string | — | no | `hysteria2_obfs_type=salamander` | Obfuscation password. |
| `hysteria2_masquerade` | string | URL | no | `protocol=hysteria2` | Masquerade URL served to non-Hysteria2 clients. |

### TLS fields

Applies to `vless`, `vmess`, `trojan` (selectable), and `hysteria2` (always TLS).

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `security` | enum | `none`, `tls`, `reality` | no | `protocol=vless/vmess/trojan` | TLS mode. Hysteria2 always forces TLS regardless of this field. |
| `tls_server_name` | string | hostname | no | `security=tls/reality` or `protocol=hysteria2` | TLS SNI / server name. |
| `tls_certificate_path` | string | file path | no | `security=tls` or `protocol=hysteria2` | Path to PEM certificate file. |
| `tls_key_path` | string | file path | no | `security=tls` or `protocol=hysteria2` | Path to PEM private key file. |
| `tls_alpn` | list | e.g. `h2`, `http/1.1` | no | `security=tls` or `protocol=hysteria2` | ALPN protocols. UCI list type; stored as repeated option values. |
| `tls_insecure` | bool | `0`/`1` | no | `security=tls/reality` or `protocol=hysteria2` | Allow insecure TLS certificates. Read by `build_tls` in `inbound.uc`. |
| `utls_fingerprint` | enum | `chrome`, `firefox`, `safari`, `edge`, `random`, `""` | no | `security=tls/reality` | uTLS client fingerprint. Empty/absent omits uTLS block. Read by `build_tls`. |
| `reality_private_key` | string | — | no | `security=reality` | Reality server private key. |
| `reality_handshake_server` | string | hostname | no | `security=reality` | Reality handshake server address. |
| `reality_handshake_server_port` | integer | port | no | `security=reality` | Reality handshake server port. |
| `reality_short_id` | string | hex | no | `security=reality` | Reality short ID. |

### Transport fields

Applies to `vless`, `vmess`, `trojan`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `transport` | enum | `none`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `http` | no | `protocol=vless/vmess/trojan` | Transport layer. Defaults to `none`. |
| `transport_path` | string | URL path | no | `transport=ws/httpupgrade/xhttp/http` | HTTP path for the transport. |
| `transport_host` | string | hostname | no | `transport=ws/httpupgrade` | HTTP Host header override (single value). |
| `transport_hosts` | list | hostnames | no | `transport=http` | HTTP host list. UCI list type. |
| `transport_service_name` | string | — | no | `transport=grpc` | gRPC service name. |
| `transport_xhttp_mode` | enum | `auto`, `packet-up`, `stream-up`, `stream-one` | no | `transport=xhttp` | XHTTP operating mode. Defaults to `auto`. |

### Multiplex fields

Applies to `vless`, `vmess`, `trojan` when `multiplex_enabled=1`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `multiplex_enabled` | bool | `0`/`1` | no | `protocol=vless/vmess/trojan` | Enables multiplex. |
| `multiplex_protocol` | enum | `smux`, `yamux`, `h2mux` | no | `multiplex_enabled=1` | Multiplex protocol. Defaults to `smux`. |
| `multiplex_max_connections` | integer | — | no | `multiplex_enabled=1` | Maximum number of multiplexed connections. |
| `multiplex_min_streams` | integer | — | no | `multiplex_enabled=1` | Minimum concurrent streams before opening a new connection. |
| `multiplex_max_streams` | integer | — | no | `multiplex_enabled=1` | Maximum streams per connection. |
| `multiplex_padding` | bool | `0`/`1` | no | `multiplex_enabled=1` | Enables stream padding. |

---

## `outbound`

UCI section type: `outbound`. Describes an outgoing connection for sing-box.

Backend: `lib/outbound.uc` — `build_outbounds()` dispatches on `type`; proxy-constructor protocols go through `build_constructor_for(s, proto)`. Subscription URL fetching is handled by `subscription.uc` which also reads several fields here.
UI write: `tabs/outbounds.js` — `buildOutboundsMap()`.

### Core fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections (`enabled=0`) are skipped by `build_outbounds`. Also checked by `subscription.uc` before fetching. |
| `type` | enum | `vless`, `vmess`, `trojan`, `hysteria2`, `shadowsocks`, `interface`, `url`, `subscription` | yes | — | Selects the outbound dispatch branch. Sections with an empty `type` are skipped. |

### Proxy-constructor common fields

Applies to `type=vless`, `vmess`, `trojan`, `hysteria2`, `shadowsocks`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server` | string | hostname or IP | yes | proxy types | Remote server address. |
| `server_port` | integer | valid port | yes | proxy types | Remote server port. Read as `s_num(s.server_port)`. |

### User credential fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_uuid` | string | UUID | yes | `type=vless` or `vmess` | Connection UUID. |
| `server_password` | string | — | yes | `type=trojan`, `hysteria2`, `shadowsocks` | Authentication password or pre-shared key. |
| `vless_flow` | enum | `none`, `xtls-rprx-vision` | no | `type=vless` | VLESS flow control. Omitted when `none`. |
| `vmess_alter_id` | integer | `0`+ | no | `type=vmess` | VMess alter ID. |
| `vmess_security` | enum | `auto`, `none`, `aes-128-gcm`, `chacha20-poly1305` | no | `type=vmess` | VMess cipher. Read by `build_constructor_for` via `s_opt(s, "vmess_security")`. |

### Shadowsocks fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `shadowsocks_method` | enum | e.g. `aes-256-gcm`, `chacha20-ietf-poly1305` | yes | `type=shadowsocks` | Encryption cipher. |

### `hysteria2` fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `hysteria2_obfs_type` | enum | `none`, `salamander` | no | `type=hysteria2` | Obfuscation type. Omitted when `none`. |
| `hysteria2_obfs_password` | string | — | no | `hysteria2_obfs_type=salamander` | Obfuscation password. |
| `up_mbps` | integer | Mbps | no | `type=hysteria2` | Upload bandwidth limit. |
| `down_mbps` | integer | Mbps | no | `type=hysteria2` | Download bandwidth limit. |
| `hysteria2_masquerade` | string | URL | no | `type=hysteria2` | Masquerade URL served to non-Hysteria2 peers. |

### TLS fields

Applies to `type=vless`, `vmess`, `trojan` (selectable via `security`). Hysteria2 always uses TLS — `security` field is absent from its UI branch but `tls_server_name` and other TLS options apply.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `security` | enum | `none`, `tls`, `reality` | no | `type=vless/vmess/trojan` | TLS mode. Defaults to `none`. |
| `tls_server_name` | string | hostname | no | `security=tls/reality` or `type=hysteria2` | TLS SNI. |
| `tls_insecure` | bool | `0`/`1` | no | `security=tls/reality` or `type=hysteria2` | Allow insecure certificates. |
| `tls_alpn` | list | e.g. `h2`, `http/1.1` | no | `security=tls` or `type=hysteria2` | ALPN protocols. UCI list type. Read as `as_array(s.tls_alpn)`. |
| `utls_fingerprint` | enum | `chrome`, `firefox`, `safari`, `edge`, `random`, `""` | no | `security=tls/reality` | uTLS client fingerprint. Empty/absent omits uTLS block. |
| `reality_public_key` | string | — | no | `security=reality` | Reality server public key (outbound-side; contrast inbound's `reality_private_key`). |
| `reality_short_id` | string | hex | no | `security=reality` | Reality short ID. |

### Transport fields

Applies to `type=vless`, `vmess`, `trojan`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `transport` | enum | `none`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `http` | no | proxy constructor types | Transport layer. Defaults to `none`. |
| `transport_path` | string | URL path | no | `transport=ws/httpupgrade/xhttp/http` | HTTP path. |
| `transport_host` | string | hostname | no | `transport=ws/httpupgrade` | HTTP Host header override (single value). |
| `transport_hosts` | list | hostnames | no | `transport=http` | HTTP host list. UCI list type. Read as `as_array(s.transport_hosts)`. |
| `transport_service_name` | string | — | no | `transport=grpc` | gRPC service name. |
| `transport_xhttp_mode` | enum | `auto`, `packet-up`, `stream-up`, `stream-one` | no | `transport=xhttp` | XHTTP operating mode. |

### Multiplex fields

Applies to `type=vless`, `vmess`, `trojan` when `multiplex_enabled=1`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `multiplex_enabled` | bool | `0`/`1` | no | `type=vless/vmess/trojan` | Enables multiplex. |
| `multiplex_protocol` | enum | `smux`, `yamux`, `h2mux` | no | `multiplex_enabled=1` | Multiplex sub-protocol. Defaults to `smux`. |
| `multiplex_max_connections` | integer | — | no | `multiplex_enabled=1` | Maximum multiplexed connections. |
| `multiplex_min_streams` | integer | — | no | `multiplex_enabled=1` | Minimum streams before opening a new connection. |
| `multiplex_max_streams` | integer | — | no | `multiplex_enabled=1` | Maximum streams per connection. |
| `multiplex_padding` | bool | `0`/`1` | no | `multiplex_enabled=1` | Enables stream padding. |

### Interface outbound (`type=interface`)

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `interface` | string | device name | yes | `type=interface` | UCI logical interface name (e.g. `wan`) or real netdev. Backend resolves via `helpers.resolve_iface_device()` before binding; falls back to the value verbatim if resolution fails. |

### Share-link URL outbound (`type=url`)

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `proxy_url` | string | proxy share-link URI | yes | `type=url` | A single proxy share link (e.g. `vless://…`, `ss://…`). Parsed by `parse_proxy_url()` at config-generation time. |

### Subscription outbound (`type=subscription`)

Subscription URL and update policy are stored on the outbound UCI section itself. The actual resolved proxy URLs are written by `subscription.uc` to `$TMPDIR/sub_<name>.txt` and read back by `outbound.uc` at config-generation time — `outbound.uc` never reads `sub_url` or `sub_interval` directly.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `sub_url` | string | HTTPS URL | yes | `type=subscription` | Subscription feed URL. Read by `subscription.uc` (`cmd_fetch_subs`) to download the proxy list; **not read by `outbound.uc`**. |
| `sub_update_via` | string | `direct` or outbound section name | no | `type=subscription` | Route through which the subscription is fetched. `direct` = default WAN; an `interface`-type outbound section name = that WAN device. Read by `subscription.uc`; **not read by `outbound.uc`**. |
| `sub_interval` | integer | seconds | no | `type=subscription` | Auto-refresh interval in seconds. Read by `subscription.uc` scheduler; **not read by `outbound.uc`**. |
| `sub_multi` | bool | `0`/`1` | no | `type=subscription` | When `1`, all parsed proxy URLs are expanded into individual child outbounds grouped under a selector or urltest group. When `0`, only the first parseable URL is used. Read by `outbound.uc`. |
| `sub_selector_type` | enum | `selector`, `urltest` | no | `sub_multi=1` | Group type for expanded proxies. Defaults to `selector`. Read by `outbound.uc`. |
| `sub_urltest_url` | string | URL | no | `sub_selector_type=urltest` | Connectivity-test URL for the urltest group. Read by `outbound.uc`. |

## `ruleset`

UCI section type: `ruleset`. Named (non-anonymous) sections. Describes remote or local rule-set files referenced by route rules and DNS rules.

Backend: `lib/ruleset.uc` — `build_rule_sets(cur, referenced_names)`. Only rulesets whose name appears in `referenced_names` (computed by `route.uc`) **and** whose `enabled` is not `"0"` are emitted. `format` is **not stored as a UCI field**; it is auto-detected from the file extension at runtime (`detect_format` in `helpers.uc`): `.srs` → `binary`, `.json` → `source`. `subscription.uc` also reads `enabled`, `update_interval`, and `nft_rules` to decide when to re-download.

UI write: `tabs/rulesets.js` — `buildRulesetsMap()`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled rulesets are silently dropped by both `ruleset.uc` and `subscription.uc`. |
| `type` | enum | `remote`, `local` | yes | — | Source type. Defaults to `remote` if absent. |
| `url` | string | HTTPS URL | yes | `type=remote` | Download URL for the rule-set file (`.srs` or `.json`). Read by `subscription.uc` during fetch; stored path used by `ruleset.uc`. |
| `path` | string | absolute file path | yes | `type=local` | Path to the local rule-set file on the router filesystem. Read by `ruleset.uc` to emit `path` in the sing-box config. |
| `nft_rules` | bool | `0`/`1` | no | — | UI-only flag: `subscription.uc` iterates over rulesets with `nft_rules=1` to decide which to keep fresh. **Not read by `ruleset.uc`** (nftables integration is handled outside generate.uc). Default `0`. |
| `update_interval` | integer | seconds | no | `type=remote` | Minimum age (seconds) before `subscription.uc` re-downloads the ruleset. Defaults to `86400` (24 h) when absent or `0`. **Not read by `ruleset.uc`**. |

---

## `route_rule`

UCI section type: `route_rule`. Named, sortable. Each section maps one or more rule-sets to a routing action.

Backend: `lib/route.uc` — `build_route_rules(cur)`. Sections with `enabled=0` are skipped. The `ruleset` list is resolved against enabled ruleset sections; if the resolved list is empty the entire rule is skipped. The backend translates the UCI `action` value to a sing-box 1.11+ rule object (replacing the removed `block` outbound with `action: "reject"`).

UI write: `tabs/routing.js` — `buildRouteRulesMap()`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections are skipped entirely by `build_route_rules`. |
| `ruleset` | list | ruleset section names | yes | — | One or more names of `ruleset` sections to match. UCI list type (multi-value). Disabled or missing ruleset names are silently filtered; if filtering empties the list the rule is dropped. |
| `action` | enum | `direct`, `block`, `outbound` | yes | — | Routing decision. `direct` → `outbound: "direct"`. `block` → emits `action: "reject"` (no outbound). `outbound` → routes to the named outbound below. Defaults to `direct`. |
| `outbound` | string | outbound section name | yes (when `action=outbound`) | `action=outbound` | Target outbound tag. **Not read when `action` is `direct` or `block`**. |

---

## `route_default`

UCI section type: `route_default`. **Singleton named section** (the section's UCI name is literally `route_default`). Describes the final (default) route applied to traffic that matches no rule.

Backend: `lib/route.uc` — reads via `cur.get_all("singbox-ui", "route_default")`. Absent section → no `route.final` is emitted. `action=block` is translated to a trailing catch-all `action: "reject"` rule appended to `route.rules` instead of setting `route.final`, because sing-box 1.11+ removed the `block` outbound.

UI write: `tabs/routing.js` — `buildRouteDefaultMap()`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `action` | enum | `direct`, `block`, `outbound` | yes | — | Default routing decision. `direct` → `route.final = "direct"`. `block` → appends a final catch-all `action: "reject"` rule; no `route.final`. `outbound` → `route.final = <outbound>`. Defaults to `direct`. |
| `outbound` | string | outbound section name | yes (when `action=outbound`) | `action=outbound` | Target outbound tag for the final route. |

## `dns`

TBD — populated in Task 21.

## `dns_server`

TBD — populated in Task 21.

## `dns_rule`

TBD — populated in Task 21.

## `cache`

TBD — populated in Task 22.

## `log`

TBD — populated in Task 22.

## `clash_api`

TBD — populated in Task 22.

## `subscription`

TBD — populated in Task 22.
