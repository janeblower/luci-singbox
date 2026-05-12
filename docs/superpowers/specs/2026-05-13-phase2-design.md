# singbox-ui Phase 2 — Spec

## Goal

Extend the LuCI app with:
1. Tabbed UI (Input / Output)
2. Outbounds management with routing conditions
3. Proper init.d service with full sing-box lifecycle
4. Standard Apply button replacing the custom Generate button
5. nftables auto-applied by the service, not a separate checkbox

No Lua anywhere — all server-side logic is ucode. Existing `generate.lua` and `singbox_ui_config.lua` are deleted.

---

## Files changed / added

| File | Change |
|---|---|
| `htdocs/.../main.js` | Full rewrite — tabs, outbounds, Apply flow |
| `root/etc/config/singbox-ui` | Remove nftables section, add outbound examples |
| `root/etc/uci-defaults/99-luci-app-singbox-ui` | Remove nftables defaults |
| `root/etc/init.d/singbox-ui` | **New** — procd service |
| `root/etc/singbox-ui/nftables.sh` | No change |
| `root/usr/libexec/rpcd/singbox-ui` | Add `restart` method, remove Lua references |
| `root/usr/share/singbox-ui/generate.uc` | Extend — outbounds + routing rules + URL parser |
| `root/usr/share/singbox-ui/generate.lua` | **Deleted** |
| `root/usr/share/singbox-ui/singbox_ui_config.lua` | **Deleted** |
| `root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json` | Add `restart` to ubus list |
| `luci-app-singbox-ui/Makefile` | Install init.d, remove lua files |
| `tests/test_generate_smoke.lua` | **Deleted** (replaced by shell test) |
| `tests/test_singbox_ui_config.lua` | **Deleted** |
| `tests/helpers.lua` | **Deleted** |
| `tests/test_generate.sh` | **New** — ucode-based smoke test |

---

## UCI Schema

```
# /etc/config/singbox-ui

config fakeip 'fakeip'
    option enabled '0'
    list inet4_range '198.18.0.0/15'
    list inet6_range 'fc00::/18'

config tproxy 'tproxy'
    option enabled '0'
    option interface 'br-lan'
    option port '7893'

# nftables section removed — applied automatically by the service

config outbound 'direct_out'
    option action 'direct'

config outbound 'block_out'
    option action 'block'

# proxy via interface
config outbound 'via_wg0'
    option action 'proxy'
    option proxy_type 'interface'
    option interface 'wg0'
    list ruleset 'https://example.com/geosite.srs'
    list domain 'google.com'

# proxy via share link
config outbound 'my_vless'
    option action 'proxy'
    option proxy_type 'url'
    option proxy_url 'vless://uuid@host:443?security=tls&sni=host'
    list ruleset '/etc/singbox-ui/rules.json'
    list domain 'youtube.com'
    list domain 'googlevideo.com'
```

Field rules:
- `action`: `block | direct | proxy` (required)
- `proxy_type`: `interface | url` — only present when `action = proxy`
- `interface`: network device name — only when `proxy_type = interface`
- `proxy_url`: share link URL — only when `proxy_type = url`
- `ruleset`: zero or more. URL → `type: remote`; filesystem path → `type: local`. Extension `.srs` → `format: binary`; `.json` → `format: source`
- `domain`: zero or more domain/subdomain strings

---

## UI — main.js

### Tab layout

`render()` builds two `form.Map` instances, renders both, wraps results in a tab container:

```
┌──────────────────────────────────────────┐
│ [ Input ]  [ Output ]                    │
├──────────────────────────────────────────┤
│  (active tab content)                    │
└──────────────────────────────────────────┘
```

Tab switching via `onclick` that toggles `display:none` on the two content nodes. Active tab header gets CSS class `cbi-tab-active`.

### Input tab — m_input (form.Map 'singbox-ui')

Sections identical to current, minus the nftables section:
- `form.NamedSection 'fakeip'` — Enable, IPv4 ranges, IPv6 ranges
- `form.NamedSection 'tproxy'` — Enable, Interface (ListValue of devices), Port

nftables checkbox removed entirely. No `syncNftables` logic.

### Output tab — m_output (form.Map 'singbox-ui')

`form.TypedSection` type `outbound`, `addremove = true`, `anonymous = false`.

**Sub-tab: Settings**
```
section.tab('settings', _('Settings'))
```
| Widget | Field | Condition |
|---|---|---|
| ListValue | `action`: block / direct / proxy | always |
| ListValue | `proxy_type`: interface / url | `action = proxy` |
| ListValue (devices) | `interface` | `action=proxy, proxy_type=interface` |
| Value | `proxy_url` | `action=proxy, proxy_type=url` |

Conditional display uses `option.depends({ action: 'proxy' })` and `option.depends({ action: 'proxy', proxy_type: 'interface' })`.

**Sub-tab: Conditions**
```
section.tab('conditions', _('Conditions'))
```
| Widget | Field | Notes |
|---|---|---|
| DynamicList | `ruleset` | URL or FS path to .srs / .json |
| DynamicList | `domain` | Domain/subdomain strings |

### Apply flow

```
RPC bindings:
  callRestart  → singbox-ui.restart
  callNftables → removed

handleSave(ev):
  return Promise.all([m_input.save(), m_output.save()])

handleSaveApply(ev):
  return handleSave(ev)
    .then(() => callRestart())
    .then(status => show notification ok/fail)

handleApply: null
handleReset: null
```

The old standalone Generate Config button is removed. The old `syncNftables` function is removed.

---

## Service — `/etc/init.d/singbox-ui`

Procd service. Manages the full sing-box lifecycle. The upstream sing-box init.d should be disabled to avoid conflicts (documented in README).

```sh
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=01

GENERATE_UC=/usr/share/singbox-ui/generate.uc
NFTABLES_SH=/etc/singbox-ui/nftables.sh

start_service() {
    ucode "$GENERATE_UC"
    [ "$(uci -q get singbox-ui.tproxy.enabled)" = "1" ] && \
        "$NFTABLES_SH" apply

    procd_open_instance
    procd_set_param command /usr/bin/sing-box run -c /tmp/singbox-ui.json
    procd_set_param respawn
    procd_close_instance
}

stop_service() {
    "$NFTABLES_SH" remove
}

reload_config() {
    # sing-box does not support signal-based config reload — full restart required.
    stop
    start
}
```

`stop_service` is called by procd automatically on `stop` and `disable` — the nftables table is always cleaned up.

---

## rpcd handler

New method `restart` added alongside `generate` and `nftables`:

```sh
restart)
    cat >/dev/null
    if /etc/init.d/singbox-ui restart >/dev/null 2>&1; then
        emit_ok
    else
        emit_err "service restart failed"
    fi
    ;;
```

`emit_list` updated:
```json
{
    "generate": {},
    "nftables": { "action": "string" },
    "restart": {}
}
```

The `generate` method is kept in the rpcd handler (used by `test_rpcd_handler.sh`) but is no longer called from the UI — config is now regenerated as part of `start_service()` in the init.d.

Comment referencing `generate.lua` updated to `generate.uc`.

---

## generate.uc — extensions

### Outbounds

Iterate all UCI sections of type `outbound`. For each:

**action = direct**
```json
{ "tag": "<section_name>", "type": "direct" }
```

**action = block**
```json
{ "tag": "<section_name>", "type": "block" }
```

**action = proxy, proxy_type = interface**
```json
{ "tag": "<section_name>", "type": "direct", "bind_interface": "<interface>" }
```

**action = proxy, proxy_type = url**
Call `parse_proxy_url(url)` → returns a sing-box outbound object. Tag is overwritten with section_name. On parse failure: warn to stderr, skip section.

### URL parser — `parse_proxy_url(url)`

Implemented as a function in generate.uc.

| URL scheme | sing-box type | Extracted fields |
|---|---|---|
| `vless://` | `vless` | uuid (userinfo), server (host), server_port (port), tls settings from query params (`security`, `sni`, `fp`, `pbk`), transport from `type` query param |
| `hy2://` or `hysteria2://` | `hysteria2` | password (userinfo), server, server_port, sni from query `sni`, obfs from query `obfs`/`obfs-password` |

Unknown scheme → `warn()` + return `null` (section skipped).

### Routing rules

After building the outbounds list, build `route.rules` and `route.rule_set` arrays.

For each outbound section that has at least one `ruleset` or `domain`:

```json
// route.rules entry
{
    "rule_set": ["rs_<name>_0", "rs_<name>_1"],
    "domain_suffix": ["google.com", "youtube.com"],
    "outbound": "<name>"
}

// route.rule_set entries
{
    "tag": "rs_<name>_<i>",
    "type": "remote",        // or "local" for FS paths
    "format": "binary",      // .srs → binary, .json → source
    "url": "https://..."     // or "path": "/etc/..." for local
}
```

Rule-set tag format: `rs_<section_name>_<index>`.

FS path detection: value starts with `/`.
Format detection: value ends with `.srs` → `binary`; `.json` → `source`.

If an outbound has no rulesets and no domains, no routing rule is generated for it (it can still be referenced manually or act as fallback).

### Full generated JSON structure

```json
{
    "dns": { "fakeip": { ... } },
    "inbounds": [ { "type": "tproxy", ... } ],
    "outbounds": [ ... ],
    "route": {
        "rules": [ ... ],
        "rule_set": [ ... ]
    }
}
```

Sections omitted if their UCI `enabled = 0` or if there are no outbounds / no routing rules.

---

## ACL — `luci-app-singbox-ui.json`

```json
{
    "luci-app-singbox-ui": {
        "description": "Grant LuCI access to singbox-ui",
        "read": {
            "uci": ["singbox-ui"],
            "ubus": {
                "singbox-ui": ["generate", "nftables", "restart"]
            }
        },
        "write": {
            "uci": ["singbox-ui"]
        }
    }
}
```

---

## Makefile changes

- Install `root/etc/init.d/singbox-ui` via `$(INSTALL_BIN)`
- Remove install lines for `generate.lua` and `singbox_ui_config.lua`
- `LUCI_DEPENDS` stays: `+luci-base +nftables +sing-box`

---

## Test changes

Lua tests deleted: `test_generate_smoke.lua`, `test_singbox_ui_config.lua`, `helpers.lua`.

New `tests/test_generate.sh` — shell test that:
1. Writes a minimal UCI config to a temp file
2. Runs `ucode generate.uc` with `UCI_CONFIG_DIR` overridden
3. Validates the output JSON contains expected keys (inbounds, outbounds, route)

Existing shell tests (`test_nftables_emit.sh`, `test_rpcd_handler.sh`) updated to cover `restart` method.

---

## Out of scope

- Editing sing-box's own global options (log, experimental, etc.)
- Import/export of full sing-box config JSON
- DNS server configuration beyond FakeIP
- UI for enabling/disabling the service (done via LuCI Services menu or SSH)
