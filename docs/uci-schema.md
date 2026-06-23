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

Source file: `luci-singbox-ui/root/etc/uci-defaults/99-luci-singbox-ui`. The script runs once on package install/upgrade (OpenWrt `uci-defaults` mechanism) and removes itself on success. Every migration is idempotent — the script may re-run on upgrade without harm.

### Migration: `fakeip-list-to-option`

**What:** Convert legacy list-typed `inet4_range` / `inet6_range` on the `fakeip` dns_server section into scalar options.

**Effect:** sing-box 1.12+ rejects array-form CIDR ranges. If either field is a multi-value UCI list, only the first element is kept (a warning is logged via `logger`); the rest are dropped. No change if the field is already a scalar.

**Idempotent:** yes — guard: `uci get singbox-ui.fakeip.<field>` returns empty when absent.

**Introduced:** commit `2f8175b` (fix(fakeip): use single CIDR per family, align UI/UCI/generate/nft).

---

### Migration: `tproxy-section-to-inbound`

**What:** Promote the legacy singleton `tproxy` section (type `tproxy`) to a proper named `inbound` section (`tproxy_in`, protocol `tproxy`).

**Effect:** Reads `enabled`, `port`, `hijack_dns`, and `interface` from the old `tproxy` section; creates `singbox-ui.tproxy_in='inbound'` with equivalent fields (`listen_port`, `hijack_dns`, `interface` list, `nft_rules=1`, `protocol=tproxy`, `listen=::`) and deletes the `tproxy` section. The Inbounds tab replaced the old implicit-tproxy model.

**Idempotent:** yes — guard: only executes when `uci get singbox-ui.tproxy` returns the section type `tproxy`.

**Introduced:** commit `1949d72` (feat(migrate): tproxy section → inbound; drop per-outbound expose options).

---

### Migration: `drop-expose-options`

**What:** Remove per-outbound `expose_*` options that were removed from the schema.

**Effect:** Iterates all `outbound` sections and deletes any option whose name begins with `expose_` (e.g. `expose_proxy`, `expose_socks`, `expose_http`). Commits only when at least one deletion occurred.

**Idempotent:** yes — `uci delete` on a non-existent option is a no-op (errors suppressed).

**Introduced:** commit `1949d72` (feat(migrate): tproxy section → inbound; drop per-outbound expose options).

---

### Migration: `ensure-default-sections`

**What:** Create default named sections for Phase 2 features if they do not already exist.

**Effect:** Creates the `fakeip` (`dns_server`), `dns` (`dns`), `route_default` (`route_default`), and `log` (`log`) sections with safe defaults so users see these tabs populated in LuCI without manually editing UCI. Skips creation for any section that already exists.

**Idempotent:** yes — uses `uci set` only when `uci get` returns empty for the section type.

**Introduced:** commit `2868067` (feat(dns): migrate fakeip/dns_outbound/ruleset.dns_fakeip to typed model).

---

### Migration: `dns-outbound-to-server`

**What:** Convert the legacy singleton `dns_outbound` section into a typed `dns_server` section named `out_dns`.

**Effect:** Reads `address` and `detour` from the old `dns_outbound` section, parses the address to determine the DNS transport type (`https`, `tls`, `udp`), creates `singbox-ui.out_dns='dns_server'` with `enabled=1`, `type`, `server`, `server_port`, `path`, and `detour` fields, then deletes `singbox-ui.dns_outbound`. If no `dns_outbound` section exists, nothing happens.

**Idempotent:** yes — guard: only runs while `uci get singbox-ui.dns_outbound` returns `dns_outbound`.

**Introduced:** commit `2868067` (feat(dns): migrate fakeip/dns_outbound/ruleset.dns_fakeip to typed model).

---

### Migration: `ensure-clash-api-secret`

**What:** Create the `clash_api` section with a stable random secret if it does not yet exist.

**Effect:** If `singbox-ui.clash_api` does not exist, creates it as type `clash_api` with `enabled=0`, `listen=127.0.0.1`, `port=9090`, and a 16-byte hex secret generated from `/dev/urandom`. If the section already exists but has no `secret`, adds one. Existing secrets are never overwritten.

**Idempotent:** yes — skips secret generation when `secret` is already non-empty.

**Introduced:** commit `1d16259` (feat(monitoring): default clash_api section + generated secret).

---

### Migration: `cache-storage-mode`

**What:** Convert the legacy `cache` section (which had `enabled`, an explicit `/tmp` `path`, and no `storage` field) to the storage-mode model.

**Effect:** Ensures a `cache` section exists (creates one if absent). If `storage` is already set, exits early. Otherwise: if the legacy `path` points to a `/tmp/…` location, sets `storage=ram`; if it points elsewhere, sets `storage=flash`; if unknown, defaults to `ram`. Preserves the existing `enabled` value. Sets `store_fakeip=1` if that field is absent. Deletes the legacy `path` option for `ram`/`flash` modes.

**Idempotent:** yes — guard: bails early if `storage` is already set.

**Introduced:** commit `9bdbe2f` (feat(cache): migrate existing cache section to storage-mode schema), with a fixup in `b3571b6` (fixup(cache-migration): preserve user-disabled state; tighten legacy gate).

---

### Migration: `ensure-dns-inbound`

**What:** Create a default DNS inbound section (`dns_in`) if one does not yet exist.

**Effect:** Creates `singbox-ui.dns_in='inbound'` with `protocol=direct`, `enabled=1`, `listen=::`, `listen_port=53`, `network=udp`, `dns_listener=1` so that the daemon has a DNS listener available by default. Skips creation if a section named `dns_in` already exists (user may have customised it).

**Idempotent:** yes — guard: `uci get singbox-ui.dns_in` non-empty means it already exists.

**Introduced:** commit `cf15c5a` (feat(migrate): create dns_in direct inbound on upgrade).

---

### Migration: `purge-extra-json`

**What:** Remove the deprecated `extra_json` option from all `inbound` and `outbound` sections.

**Effect:** Iterates every UCI section of type `inbound` or `outbound` and deletes the `extra_json` option. The constructor model now covers all needed fields; raw-JSON merging is removed.

**Idempotent:** yes — `uci delete` on a non-existent option is a no-op.

**Introduced:** commit `9bda227` (refactor(constructor): drop deprecated extra_json field across UI, emit, and UCI).

---

### Migration: `purge-inbound-mode-json`

**What:** Remove legacy `mode` and `inbound_json` discriminator fields from inbound sections, and disable any section that previously used `mode=json`.

**Effect:** For every `inbound` section: if `mode=json` and `inbound_json` is non-empty, sets `enabled=0` (so the daemon does not receive stale raw JSON config) and logs a warning. In all cases, deletes `mode` and `inbound_json` options. Sections that used `mode=constructor` just have the options deleted; they remain enabled. Users with `mode=json` sections must re-import via the new UI button.

**Idempotent:** yes — deleting already-absent options is harmless.

**Introduced:** commit `2c87d67` (refactor(inbound): drop mode discriminator; protocol IS the kind).

---

### Migration: `outbound-proxy-type-to-type`

**What:** Rename `proxy_type` → `type` on outbound sections, collapse the `constructor`/`protocol` model into a single `type` field, and disable `proxy_type=json` sections.

**Effect:** For every `outbound` section: if `proxy_type` is set, renames it to `type` (or to the value of the nested `protocol` field for `proxy_type=constructor`). If `proxy_type=json`, sets `enabled=0` (cannot safely migrate raw JSON), deletes `proxy_type` and `outbound_json`. If `type` already exists and `proxy_type` is absent, does nothing.

**Idempotent:** yes — guard: skips sections where `proxy_type` is absent.

**Introduced:** commit `15cf591` (refactor(outbound): rename proxy_type→type; collapse constructor+protocol; drop json mode).

---

### Migration: `migrate_rename_e2_keys`

**What:** Rename legacy UCI option keys on inbound and outbound sections so the Phase E2 DSL descriptors can read them correctly.

**Effect:** For every `inbound` and `outbound` section:
- `transport` → `transport_type` (the field was renamed in E2 to avoid a ucode keyword clash). When `transport=httpupgrade`, also splits `transport_host` → `transport_host_httpupgrade`.
- `tls_ech` → `tls_ech_enabled` (aligned with the descriptor boolean-gate naming convention).
- `security=tls` → sets `tls_enabled=1`, then deletes `security`.
- `security=reality` → sets `tls_enabled=1` and `reality_enabled=1`, then deletes `security`.
- `utls_fingerprint` non-empty → sets `utls_enabled=1` (the value is preserved unchanged).

**Idempotent:** yes — each rename fires only while the old key is present and the new key is absent.

**Introduced:** Phase E2, commit implementing T15 migrations.

---

### Migration: `drop-removed-protocols-e2`

**What:** Hard-delete UCI sections whose protocol/type was removed from the E2 UI surface.

**Effect:**
- Deletes every `inbound` section where `protocol ∈ {tun, vmess}`.
- Deletes every `outbound` section where `type ∈ {vmess, tuic, anytls, ssh, interface}`.

Deletions are logged via `logger -t singbox-ui`. A final `uci commit` is issued only when at least one section was deleted.

**Idempotent:** yes — deleting a non-existent section is a no-op.

**Introduced:** Phase E2, commit implementing T15 migrations.

---

## `inbound`

UCI section type: `inbound`. Describes an incoming listener for sing-box.

Backend: `lib/inbound.uc` — `build_one(s)` reads every field listed here.
UI write: `tabs/inbounds.js` — `buildInboundsMap()`.

### Core fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections (`enabled=0`) are skipped by `build_inbounds`. |
| `protocol` | enum | `direct`, `tproxy`, `mixed`, `shadowsocks`, `vless`, `trojan`, `hysteria2` | yes | — | Selects the protocol branch in `build_one`. `tun` and `vmess` are dropped in E2 — existing sections are deleted by migration `drop-removed-protocols-e2`. Defaults to `tproxy` if absent. Legacy field `mode` is silently ignored. |
| `listen` | string | IP address or `::` | no | all except `tun` | Bind address. Defaults to `::` if empty. |
| `listen_port` | integer | valid port | yes (except tun) | all except `tun` | Listen port. Missing/zero causes the section to be skipped with a warning. |

### `direct` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `network` | enum | `""` (both), `tcp`, `udp` | no | `protocol=direct/shadowsocks` | Restricts accepted network. Empty or any other value omits `network` from output (sing-box treats absence as tcp+udp). |
| `dns_listener` | bool | `0`/`1` | no | `protocol=direct` | UI-only: when set, the UI auto-emits a hijack-dns route rule for this inbound. **Not read by `inbound.uc`**. |

### `tproxy` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `tcp_fast_open` | bool | `0`/`1` | no | `protocol=tproxy` | Enables TCP Fast Open on the listener. |
| `udp_fragment` | bool | `0`/`1` | no | `protocol=tproxy` | Enables UDP fragment reassembly. |
| `hijack_dns` | bool | `0`/`1` | no | `protocol=tproxy` | UI-only: controls whether an nftables DNS-hijack rule is installed. **Not read by `inbound.uc`**. |
| `interface` | string (list) | device names | no | `protocol=tproxy` | UI-only: selects network interfaces for nftables rules. **Not read by `inbound.uc`**. |
| `nft_rules` | bool | `0`/`1` | no | `protocol=tproxy` or `tun` | UI-only: controls nftables rule generation. **Not read by `inbound.uc`**. |

### `mixed` protocol fields

`mixed` is a combined HTTP/SOCKS5 inbound listener. Authentication is optional — when `mixed_user` is empty, all connections are accepted without credentials.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `listen` | string | IP address or `::` | no | `protocol=mixed` | Bind address. Defaults to `::` if empty. |
| `listen_port` | integer | valid port | yes | `protocol=mixed` | Listen port. Missing/zero causes the section to be skipped with a warning. |
| `mixed_user` | list | `"username:password"` per entry | no | `protocol=mixed` | Optional user list. Each entry colon-separates the username from the password. When non-empty, only authenticated clients are accepted. Empty list → open listener (no auth). |

### `shadowsocks` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `shadowsocks_method` | enum | e.g. `aes-256-gcm`, `chacha20-ietf-poly1305` | yes | `protocol=shadowsocks` | Encryption cipher. Shared across all users when `ss_user` is non-empty. |
| `server_password` | string | — | yes (single-user) | `protocol=shadowsocks` | Shared password for the single-user mode. Ignored when `ss_user` is non-empty (multi-user `users[]` takes precedence). |
| `ss_user` | list | `"name:password"` per entry | no | `protocol=shadowsocks` | Multi-user list. Each entry colon-separates the user name from the password. When non-empty, `users[]` is emitted and top-level `server_password` is dropped. Malformed entries (no colon, empty name, or empty password) are silently skipped. |

> **Limitation — colon-in-password:** the `ss_user` entry format uses `:` as the sole field separator, so the parser splits at the **first** colon only. A password that itself contains a literal `:` will be silently truncated at that first colon (anything after it is dropped). Use a colon-free passphrase, or base64-encode the password and document the encoding alongside the section, until a richer entry format (TSV / JSON) lands.

### User credential fields (vless / trojan)

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_uuid` | string | UUID | yes (single-user) | `protocol=vless` | UUID for the single-user entry. Ignored when `inbound_user` is non-empty (multi-user `users[]` takes precedence). |
| `server_password` | string | — | yes | `protocol=trojan` | Password for the single user entry (also used by `hysteria2`). |
| `vless_flow` | enum | `none`, `xtls-rprx-vision` | no | `protocol=vless` | VLESS flow control. Omitted when `none`. Ignored when `inbound_user` is non-empty (per-user flow comes from each entry). |
| `inbound_user` | list | `name:uuid[:flow]` (vless) | no | `protocol=vless` | Multi-user list. When non-empty, emits `users[]` and ignores section-level `server_uuid` / `vless_flow`. Malformed entries (missing name or uuid) are silently skipped. Existing single-user configs continue to work unchanged; no UCI migration is required. |

### `hysteria2` protocol fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_password` | string | — | yes | `protocol=hysteria2` | Authentication password. |
| `up_mbps` | integer | Mbps | no | `protocol=hysteria2` | Upload bandwidth limit. |
| `down_mbps` | integer | Mbps | no | `protocol=hysteria2` | Download bandwidth limit. |
| `obfs_type` | enum | `none`, `salamander` | no | `protocol=hysteria2` | Obfuscation type. Omitted when `none`. |
| `obfs_password` | string | — | no | `obfs_type=salamander` | Obfuscation password. |
| `hysteria2_masquerade` | string | URL | no | `protocol=hysteria2` | Masquerade URL served to non-Hysteria2 clients. |
| `brutal_debug` | bool | `0`/`1` | no | `protocol=hysteria2` | Emit `brutal_debug` for the Brutal congestion-control debug output. |
| `ignore_client_bandwidth` | bool | `0`/`1` | no | `protocol=hysteria2` | Inbound-only flag — server ignores client-reported bandwidth (uses its own `up_mbps`/`down_mbps`). |

### TLS fields

Applies to `vless`, `trojan` (selectable via `tls_enabled`/`reality_enabled`), and `hysteria2` (always TLS). The E2 descriptor model replaces the old `security` enum with explicit boolean gates.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `tls_enabled` | bool | `0`/`1` | no | `protocol=vless/trojan` | Enables TLS. Renamed from `security=tls` by migration `migrate_rename_e2_keys`. Hysteria2 always forces TLS regardless of this field. |
| `tls_server_name` | string | hostname | no | `tls_enabled=1` or `protocol=hysteria2` | TLS SNI / server name. |
| `tls_certificate_path` | string | file path | no | `tls_enabled=1` or `protocol=hysteria2` | Path to PEM certificate file (server-side). |
| `tls_key_path` | string | file path | no | `tls_enabled=1` or `protocol=hysteria2` | Path to PEM private key file (server-side). |
| `tls_alpn` | list | e.g. `h2`, `http/1.1` | no | `tls_enabled=1` or `protocol=hysteria2` | ALPN protocols. UCI list type; stored as repeated option values. |
| `tls_insecure` | bool | `0`/`1` | no | `tls_enabled=1` or `protocol=hysteria2` | Allow insecure TLS certificates. |
| `tls_min_version` | enum | `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"` | no | `tls_enabled=1` | Minimum TLS version. Empty/absent omits the field (sing-box default). |
| `tls_max_version` | enum | `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"` | no | `tls_enabled=1` | Maximum TLS version. Empty/absent omits the field. |
| `tls_cipher_suites` | list | TLS cipher suite names | no | `tls_enabled=1` | Cipher suites. UCI list type; emitted as `tls.cipher_suites[]`. |
| `utls_enabled` | bool | `0`/`1` | no | `tls_enabled=1` (inbound: server-side, n/a for inbound) | Sub-gate for uTLS. Renamed by migration; uTLS is client-only so inbound ignores this field. |
| `utls_fingerprint` | enum | `chrome`, `firefox`, `safari`, `edge`, `random`, `""` | no | `utls_enabled=1` | uTLS client fingerprint. Empty/absent omits uTLS block. |
| `reality_enabled` | bool | `0`/`1` | no | `tls_enabled=1` | Enables Reality mode. Renamed from `security=reality` by migration `migrate_rename_e2_keys`. |
| `reality_private_key` | string | — | no | `reality_enabled=1` | Reality server private key (inbound-side). |
| `reality_handshake_server` | string | hostname | no | `reality_enabled=1` | Reality handshake server address. |
| `reality_handshake_server_port` | integer | port | no | `reality_enabled=1` | Reality handshake server port. |
| `reality_short_id` | string | hex (0-8 chars) | no | `reality_enabled=1` | Reality short ID. Single string per sing-box 1.12 docs (`tls.reality.short_id`). |
| `tls_ech_enabled` | bool | `0`/`1` | no | `tls_enabled=1` or `protocol=hysteria2` | Enable ECH (Encrypted ClientHello). Renamed from `tls_ech` by migration `migrate_rename_e2_keys`. Emits `tls.ech.enabled`. |
| `tls_ech_key` | list | PEM lines | no | `tls_ech_enabled=1` | Inline ECH key (server-side). UCI list type; emitted as `tls.ech.key[]`. |
| `tls_ech_key_path` | string | file path | no | `tls_ech_enabled=1` | Path to ECH key file. Emitted as `tls.ech.key_path`. |

> **Note:** sing-box 1.12 also defines `tls.ech.pq_signature_schemes_enabled` and `tls.ech.dynamic_record_sizing_disabled`, but both are deprecated in 1.12 and removed in 1.13 — never emitted by this package.

### Transport fields

Applies to `vless`, `trojan` (inbound). The field `transport` was renamed to `transport_type` by migration `migrate_rename_e2_keys`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `transport_type` | enum | `none`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `http` | no | `protocol=vless/trojan` | Transport layer. Renamed from `transport` in E2. Defaults to `none`. |
| `transport_path` | string | URL path | no | `transport_type=ws/httpupgrade/xhttp/http` | HTTP path for the transport. |
| `transport_host` | string | hostname | no | `transport_type=ws` | HTTP Host header override for WebSocket (single value). |
| `transport_host_httpupgrade` | string | hostname | no | `transport_type=httpupgrade` | HTTP Host header override for HTTPUpgrade. Split from `transport_host` in E2. |
| `transport_hosts` | list | hostnames | no | `transport_type=http` | HTTP host list. UCI list type. |
| `transport_service_name` | string | — | no | `transport_type=grpc` | gRPC service name. |
| `transport_xhttp_mode` | enum | `auto`, `packet-up`, `stream-up`, `stream-one` | no | `transport_type=xhttp` | XHTTP operating mode. Defaults to `auto`. |
| `transport_max_early_data` | integer | bytes | no | `transport_type=ws/httpupgrade/xhttp` | Maximum TLS early data size. |
| `transport_early_data_header_name` | string | header name | no | `transport_max_early_data` set | HTTP header name for early data. |

### Multiplex fields

Applies to `vless`, `trojan`, `shadowsocks` (inbound) when `multiplex_enabled=1`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `multiplex_enabled` | bool | `0`/`1` | no | `protocol=vless/trojan/shadowsocks` | Enables multiplex. |
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
| `type` | enum | `vless`, `trojan`, `hysteria2`, `shadowsocks`, `direct`, `url`, `subscription` | yes | — | Selects the outbound dispatch branch. Sections with an empty `type` are skipped. `vmess`, `tuic`, `anytls`, `ssh`, `interface` are dropped in E2 — existing sections are deleted by migration `drop-removed-protocols-e2`. |

### Proxy-constructor common fields

Applies to `type=vless`, `trojan`, `hysteria2`, `shadowsocks`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server` | string | hostname or IP | yes | proxy types | Remote server address. |
| `server_port` | integer | valid port | yes | proxy types | Remote server port. Read as `s_num(s.server_port)`. |

### User credential fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `server_uuid` | string | UUID | yes | `type=vless` | Connection UUID. |
| `server_password` | string | — | yes | `type=trojan`, `hysteria2`, `shadowsocks` | Authentication password or pre-shared key. |
| `vless_flow` | enum | `none`, `xtls-rprx-vision` | no | `type=vless` | VLESS flow control. Omitted when `none`. |

### Shadowsocks fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `shadowsocks_method` | enum | e.g. `aes-256-gcm`, `chacha20-ietf-poly1305` | yes | `type=shadowsocks` | Encryption cipher. |
| `plugin` | string | e.g. `obfs-local` | no | `type=shadowsocks` | SIP003 plugin name. |
| `plugin_opts` | string | plugin option string | no | `plugin` set | SIP003 plugin options. |
| `udp_over_tcp` | bool | `0`/`1` | no | `type=shadowsocks` | Enables UDP-over-TCP multiplexing. |
| `network` | enum | `""`, `tcp`, `udp` | no | `type=shadowsocks` | Restricts the dialed network. Empty or any other value omits the field. |

### `hysteria2` fields

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `obfs_type` | enum | `none`, `salamander` | no | `type=hysteria2` | Obfuscation type. Omitted when `none`. |
| `obfs_password` | string | — | no | `obfs_type=salamander` | Obfuscation password. |
| `up_mbps` | integer | Mbps | no | `type=hysteria2` | Upload bandwidth limit. |
| `down_mbps` | integer | Mbps | no | `type=hysteria2` | Download bandwidth limit. |
| `masquerade` | string | URL | no | `type=hysteria2` | Masquerade URL served to non-Hysteria2 peers. |
| `brutal_debug` | bool | `0`/`1` | no | `type=hysteria2` | Emit `brutal_debug` for Brutal CC debug output. |
| `network` | enum | `""`, `tcp`, `udp` | no | `type=hysteria2` | Restricts the dialed network. Empty or any other value omits the field. |

### TLS fields

Applies to `type=vless`, `trojan` (selectable via `tls_enabled`/`reality_enabled`). Hysteria2 always uses TLS — `tls_enabled` is absent from its branch but `tls_server_name` and other TLS options apply. The E2 descriptor model uses explicit boolean gates instead of the old `security` enum.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `tls_enabled` | bool | `0`/`1` | no | `type=vless/trojan` | Enables TLS. Renamed from `security=tls` by migration `migrate_rename_e2_keys`. |
| `tls_server_name` | string | hostname | no | `tls_enabled=1` or `type=hysteria2` | TLS SNI. |
| `tls_insecure` | bool | `0`/`1` | no | `tls_enabled=1` or `type=hysteria2` | Allow insecure certificates. |
| `tls_alpn` | list | e.g. `h2`, `http/1.1` | no | `tls_enabled=1` or `type=hysteria2` | ALPN protocols. UCI list type. Read as `as_array(s.tls_alpn)`. |
| `tls_min_version` | enum | `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"` | no | `tls_enabled=1` | Minimum TLS version. |
| `tls_max_version` | enum | `"1.0"`, `"1.1"`, `"1.2"`, `"1.3"` | no | `tls_enabled=1` | Maximum TLS version. |
| `tls_cipher_suites` | list | TLS cipher suite names | no | `tls_enabled=1` | Cipher suites. UCI list type; emitted as `tls.cipher_suites[]`. |
| `utls_enabled` | bool | `0`/`1` | no | `tls_enabled=1` | Sub-gate for uTLS client fingerprint emulation. |
| `utls_fingerprint` | enum | `chrome`, `firefox`, `safari`, `edge`, `random`, `""` | no | `utls_enabled=1` | uTLS client fingerprint. Empty/absent omits uTLS block. |
| `reality_enabled` | bool | `0`/`1` | no | `tls_enabled=1` | Enables Reality mode. Renamed from `security=reality` by migration. |
| `reality_public_key` | string | — | no | `reality_enabled=1` | Reality server public key (outbound-side). |
| `reality_short_id` | string | hex (0-8 chars) | no | `reality_enabled=1` | Reality short ID. Single string per sing-box 1.12 docs. |
| `tls_ech_enabled` | bool | `0`/`1` | no | `tls_enabled=1` or `type=hysteria2` | Enable ECH (Encrypted ClientHello). Renamed from `tls_ech` by migration. Emits `tls.ech.enabled`. |
| `tls_ech_config` | list | PEM lines | no | `tls_ech_enabled=1` | Inline ECH config (client-side). UCI list type; emitted as `tls.ech.config[]`. |
| `tls_ech_config_path` | string | file path | no | `tls_ech_enabled=1` | Path to ECH config file. Emitted as `tls.ech.config_path`. |
| `tls_fragment` | bool | `0`/`1` | no | `type=vless/trojan/hysteria2` | Enable TLS handshake fragmentation. Since sing-box 1.12. Flat field `tls.fragment`. |
| `tls_fragment_fallback_delay` | string | duration (e.g. `500ms`) | no | `tls_fragment=1` | Fragment fallback delay. Defaults to `500ms` in sing-box. |
| `tls_record_fragment` | bool | `0`/`1` | no | `type=vless/trojan/hysteria2` | Split handshake across multiple TLS records. Since sing-box 1.12. Flat field `tls.record_fragment`. |

### Transport fields

Applies to `type=vless`, `trojan`. The field `transport` was renamed to `transport_type` by migration `migrate_rename_e2_keys`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `transport_type` | enum | `none`, `ws`, `grpc`, `httpupgrade`, `xhttp`, `http` | no | `type=vless/trojan` | Transport layer. Renamed from `transport` in E2. Defaults to `none`. |
| `transport_path` | string | URL path | no | `transport_type=ws/httpupgrade/xhttp/http` | HTTP path. |
| `transport_host` | string | hostname | no | `transport_type=ws` | HTTP Host header override for WebSocket (single value). |
| `transport_host_httpupgrade` | string | hostname | no | `transport_type=httpupgrade` | HTTP Host header override for HTTPUpgrade. Split from `transport_host` in E2. |
| `transport_hosts` | list | hostnames | no | `transport_type=http` | HTTP host list. UCI list type. Read as `as_array(s.transport_hosts)`. |
| `transport_service_name` | string | — | no | `transport_type=grpc` | gRPC service name. |
| `transport_xhttp_mode` | enum | `auto`, `packet-up`, `stream-up`, `stream-one` | no | `transport_type=xhttp` | XHTTP operating mode. |
| `transport_max_early_data` | integer | bytes | no | `transport_type=ws/httpupgrade/xhttp` | Maximum TLS early data size. |
| `transport_early_data_header_name` | string | header name | no | `transport_max_early_data` set | HTTP header name for early data. |

### Multiplex fields

Applies to `type=vless`, `trojan`, `shadowsocks` when `multiplex_enabled=1`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `multiplex_enabled` | bool | `0`/`1` | no | `type=vless/trojan/shadowsocks` | Enables multiplex. |
| `multiplex_protocol` | enum | `smux`, `yamux`, `h2mux` | no | `multiplex_enabled=1` | Multiplex sub-protocol. Defaults to `smux`. |
| `multiplex_max_connections` | integer | — | no | `multiplex_enabled=1` | Maximum multiplexed connections. |
| `multiplex_min_streams` | integer | — | no | `multiplex_enabled=1` | Minimum streams before opening a new connection. |
| `multiplex_max_streams` | integer | — | no | `multiplex_enabled=1` | Maximum streams per connection. |
| `multiplex_padding` | bool | `0`/`1` | no | `multiplex_enabled=1` | Enables stream padding. |

### Dial fields

Shared outbound dial options emitted by `_shared/dial.uc`. Applies to all proxy outbound types and `type=direct`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `bind_interface` | string | netdev name | no | any outbound | Bind outgoing connections to this interface. Emitted verbatim — provide the real Linux netdev (e.g. `eth0`, `pppoe-wan`); the UI offers live devices via the `interfaces` dynamic source. |
| `inet4_bind_address` | string | IPv4 address | no | any outbound | Source IPv4 address for outgoing connections. |
| `inet6_bind_address` | string | IPv6 address | no | any outbound | Source IPv6 address for outgoing connections. |
| `routing_mark` | integer | SO_MARK value | no | any outbound | Sets the `SO_MARK` socket option on outgoing connections. |
| `reuse_addr` | bool | `0`/`1` | no | any outbound | Enables `SO_REUSEADDR` on the dialing socket. |
| `connect_timeout` | string | duration (e.g. `5s`) | no | any outbound | Dial timeout. Empty/absent omits the field (sing-box default). |
| `tcp_fast_open` | bool | `0`/`1` | no | any outbound | Enables TCP Fast Open on outgoing connections. |
| `tcp_multi_path` | bool | `0`/`1` | no | any outbound | Enables TCP multi-path (MPTCP). |
| `udp_fragment` | bool | `0`/`1` | no | any outbound | Enables UDP fragmentation for outgoing datagrams. |
| `domain_strategy` | enum | `""`, `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only` | no | any outbound | Address resolution strategy for this outbound. |
| `network_strategy` | enum | `""`, `default`, `hybrid`, `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only` | no | any outbound | Network interface selection strategy. |
| `fallback_delay` | string | duration | no | `domain_strategy` set | Delay before falling back to the secondary address family. |
| `detour` | string | outbound section name | no | any outbound | Route this outbound's traffic through another outbound. |
| `netns` | string | network namespace path or name | no | any outbound | Linux network namespace for this outbound. |

### `direct` outbound fields

`type=direct` replaces the old `type=interface` outbound from pre-E2. Uses `_shared/dial.uc` for the bind interface and all dial fields above.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `override_address` | string | IP or hostname | no | `type=direct` | Replaces the destination address. |
| `override_port` | integer | port | no | `type=direct` | Replaces the destination port. |
| `proxy_protocol` | integer | `1` or `2` | no | `type=direct` | Emits PROXY Protocol header version 1 or 2 to the downstream. |

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
| `download_detour` | string | outbound section name | no | `type=remote` | Outbound tag through which sing-box fetches the rule-set (dropdown of existing outbounds; empty = direct). Emitted as `download_detour` in the `route.rule_set` entry. Deprecated in sing-box (removed in 1.16) but valid on all targeted versions (1.12+), so not version-gated. |
| `nft_rules` | bool | `0`/`1` | no | — | UI-only flag: `subscription.uc` iterates over rulesets with `nft_rules=1` to decide which to keep fresh. **Not read by `ruleset.uc`** (nftables integration is handled outside generate.uc). Default `0`. |
| `update_interval` | integer | seconds | no | `type=remote` | Auto-update interval. Two consumers: (1) `subscription.uc` uses it as the minimum age before re-downloading the `rs_*.json` for `nft_rules=1` rulesets (defaults to `86400`/24 h when absent or `0`); (2) `ruleset.uc` emits it into the sing-box `route.rule_set` entry as a duration (`"<n>s"`) when `> 0`, so sing-box auto-updates the rule-set itself — independent of `nft_rules`. Without it, a routing-only (`nft_rules=0`) rule-set would never auto-update. |

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

UCI section type: `dns`. **Singleton named section** (UCI name is literally `dns`). Controls global DNS settings.

Backend: `lib/dns.uc` — `build_dns(cur)` reads via `cur.get_all("singbox-ui", "dns")`. Absent section → global DNS options are omitted (sing-box defaults apply).

UI write: `tabs/dns.js` — `buildDnsMap()`, `form.NamedSection('dns', 'dns', …)`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `final` | string | dns_server section name | no | — | Tag of the DNS server used when no rule matches. Emitted as `dns.final`. |
| `strategy` | enum | `""` (default), `prefer_ipv4`, `prefer_ipv6`, `ipv4_only`, `ipv6_only` | no | — | Global address resolution strategy. Empty/absent omits the field (sing-box default). |
| `independent_cache` | bool | `0`/`1` | no | — | Enables per-server DNS cache isolation. Default `0`. |

> Note: `disable_cache`, `disable_expire`, `reverse_mapping`, `client_subnet`, and `default_resolver` fields anticipated in the task plan are **not present** in either `dns.uc` or `dns.js`. The backend only reads `final`, `strategy`, and `independent_cache`.

---

## `dns_server`

UCI section type: `dns_server`. Named, sortable. Each section defines one DNS upstream server.

Backend: `lib/dns.uc` — `build_servers(cur)`. Sections with `enabled=0` are skipped. Supported types are `udp`, `tls`, `https`, and `fakeip`; any other type is warned and skipped.

UI write: `tabs/dns.js` — `buildDnsMap()`, `form.GridSection('dns_server', …)`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections are skipped by `build_servers`. |
| `type` | enum | `udp`, `tls`, `https`, `fakeip` | yes | — | DNS transport / server kind. Defaults to `https` in UI. |
| `server` | string | hostname or IP | yes | `type=udp/tls/https` | DNS server address (without scheme or port). |
| `server_port` | integer | port | no | `type=udp/tls/https` | Overrides the default port for the transport. Parsed via `s_num()`. |
| `path` | string | URL path | no | `type=https` | HTTP path for DoH queries (e.g. `/dns-query`). |
| `detour` | string | outbound section name | no | `type=udp/tls/https` | Routes DNS queries through this outbound. Note: `generate.uc` scrubs references to the implicit empty `direct` outbound at startup to avoid a sing-box 1.12 fatal error. |
| `domain_resolver` | string | dns_server section name | no | `type=udp/tls/https` | Tag of another DNS server used to resolve the server's own address (sing-box `domain_resolver` field). Stored as `domain_resolver` in UCI; emitted as `domain_resolver`. |
| `inet4_range` | string | IPv4 CIDR | yes | `type=fakeip` | IPv4 range for fakeip responses (e.g. `198.18.0.0/15`). |
| `inet6_range` | string | IPv6 CIDR | no | `type=fakeip` | IPv6 range for fakeip responses (e.g. `fc00::/18`). |

> UI/backend note: the UI field label uses `domain_resolver`; the backend reads it as `s_opt(s, "domain_resolver")` and emits `domain_resolver` — consistent naming throughout.

---

## `dns_rule`

UCI section type: `dns_rule`. Named, sortable. Each section defines a DNS routing rule — matching criteria plus a target server.

Backend: `lib/dns.uc` — `build_rules(cur)`. Sections with `enabled=0` are skipped. A rule that has no matching criteria (no `rule_set`, `domain_suffix`, `domain_keyword`, or `clash_mode`) is silently dropped. Matching criteria are OR-combined; `server` must be non-empty for the rule to be emitted.

UI write: `tabs/dns.js` — `buildDnsMap()`, `form.GridSection('dns_rule', …)`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | Disabled sections are skipped by `build_rules`. |
| `ruleset` | list | ruleset section names | no | — | One or more `ruleset` section names. Disabled or missing rulesets are filtered; the surviving names become `rule_set` in the emitted rule. |
| `domain_suffix` | string | comma-separated suffixes | no | — | Domain suffixes to match. Parsed via `csv_list()` into a list; emitted as `domain_suffix`. |
| `domain_keyword` | string | comma-separated keywords | no | — | Domain keywords to match. Parsed via `csv_list()` into a list; emitted as `domain_keyword`. |
| `clash_mode` | enum | `""` (any), `global`, `direct`, `rule` | no | — | Clash operating mode filter. Empty/absent omits the field. |
| `server` | string | dns_server section name | yes (effectively) | — | Target DNS server tag. Rule is dropped if this is empty. |
| `rewrite_ttl` | integer | seconds (`0` = disable) | no | — | Forces this TTL on matched responses. Empty/absent → backend defaults to `60`. `"0"` → explicitly sets `rewrite_ttl: 0` (disables TTL rewriting). Default in UI is `60`. |

> UI/backend note: the backend (`dns.uc`) does **not** read a `disable_cache` field on `dns_rule` sections — despite being listed in the task plan. Only the 6 fields above are actually consumed.

## `cache`

UCI section type: `cache`. **Singleton named section** (UCI name is literally `cache`). Controls sing-box's `experimental.cache_file` block.

Backend: `lib/cache.uc` — `build_cache(cur)`. Absent section or `enabled=0` → returns `null` (no `experimental.cache_file` emitted). The `path` field is **derived** at runtime from the `storage` enum rather than read directly; `cache.uc` also cross-checks enabled `dns_server` sections for a `fakeip` type before emitting `store_fakeip`.

UI write: `tabs/general.js` — `buildGeneralMap()`, `form.NamedSection('cache', 'cache', …)`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | When `0` or absent, `build_cache` returns `null` and no cache block is emitted. |
| `storage` | enum | `ram`, `flash`, `custom` | no | `enabled=1` | Storage location strategy. `ram` → `/tmp/singbox-ui-cache.db` (lost on reboot). `flash` → `/etc/sing-box/cache.db` (persistent). `custom` → reads `path`. Defaults to `ram`. **Not emitted to sing-box config**; used only by `cache.uc` to resolve the actual path. |
| `path` | string | absolute file path | yes (when `storage=custom`) | `storage=custom` | Absolute path for the cache database. Required when `storage=custom`; the UI validates it at save time. Ignored by `cache.uc` for `storage=ram` or `storage=flash`. |
| `store_fakeip` | bool | `0`/`1` | no | `enabled=1` | When `1` **and** an enabled `dns_server` of type `fakeip` exists, emits `store_fakeip: true` in the cache block. Silently omitted otherwise. Default `1`. |

---

## `log`

UCI section type: `log`. **Singleton named section** (UCI name is literally `log`). Controls the sing-box `log` block.

Backend: `lib/log.uc` — `build_log(cur)`. Absent section → returns `null` (sing-box default: `info` level). `enabled=0` → emits `{ disabled: true }`.

UI write: `tabs/general.js` — `buildGeneralMap()`, `form.NamedSection('log', 'log', …)`.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | When `0`, emits `{ disabled: true }`. When `1`, emits `{ level, timestamp: true, output? }`. |
| `level` | enum | `trace`, `debug`, `info`, `warn`, `error`, `fatal`, `panic` | no | `enabled=1` | Log verbosity level. Defaults to `info` if absent. Always emitted as `timestamp: true` alongside. |
| `output` | string | file path | no | `enabled=1` | Log output file path. Empty/absent omits the field (sing-box writes to procd stdout). |

---

## `clash_api`

UCI section type: `clash_api`. **Singleton named section** (UCI name is literally `clash_api`). Controls the sing-box `experimental.clash_api` block.

Backend: `lib/clash.uc` — `build_clash_api(cur)`. Absent section or `enabled=0` → returns `null` (no `experimental.clash_api` emitted).

UI write: **none** — there is no UI tab or form for `clash_api`. The section and its defaults are provisioned exclusively by the uci-defaults script (`99-luci-singbox-ui`) at install time. `listen`, `port`, and a randomly generated `secret` are written once during package installation. Users must edit UCI directly to change these values.

| Field | Type | Values | Required | Depends on | Description |
|---|---|---|---|---|---|
| `enabled` | bool | `0`/`1` | yes | — | When `0` or absent, no `experimental.clash_api` block is emitted. Default set to `0` by uci-defaults. |
| `listen` | string | IP address | no | `enabled=1` | Bind address for the Clash-compatible API. Defaults to `127.0.0.1` if absent or empty. |
| `port` | integer | port | no | `enabled=1` | TCP port for the Clash API. Defaults to `9090` if absent or empty. |
| `secret` | string | — | no | `enabled=1` | API authentication secret. Auto-generated (16 hex bytes from `/dev/urandom`) by uci-defaults on install if not already set. Omitted from the emitted config if empty. |

---

## `subscription`

This is **not a distinct UCI section type**. Subscription configuration lives on `outbound` sections of type `subscription` (see the [`outbound` Subscription subsection](#subscription-outbound-typesubscription) above). The `subscription.uc` script reads `sub_url`, `sub_update_via`, and `sub_interval` from those outbound sections.

There is no separate UCI section named or typed `subscription`.

---

## UI form validation (`lib/validators.js`)

Pure-function validators consumed by LuCI form `.validate` callbacks. Each returns `true` on valid input or a non-empty error string that blocks "Save & Apply". Wired into `tabs/inbounds.js` and `tabs/outbounds.js`:

| Validator | Wired on |
|---|---|
| `isPort` | `listen_port` (inbound), `server_port` (outbound) |
| `isUuid` | `server_uuid` (inbound vless, outbound vless) |
| `isHost` | `server` (outbound), `tls_server_name` (inbound + outbound) |
| `isAlpnNonEmpty` | `tls_alpn` DynamicList (inbound + outbound) |
| `requiresWsPath` | `transport_path` (inbound + outbound), reads `transport_type` formvalue |
