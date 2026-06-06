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

TBD — populated in Task 19.

## `ruleset`

TBD — populated in Task 20.

## `route_rule`

TBD — populated in Task 20.

## `route_default`

TBD — populated in Task 20.

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
