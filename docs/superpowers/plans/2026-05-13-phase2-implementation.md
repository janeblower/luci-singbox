# singbox-ui Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add tabbed UI (Input/Output), Outbounds management, procd service lifecycle, and Apply-driven config generation — replacing the standalone Generate button.

**Architecture:** The LuCI page splits into two `form.Map` instances (Input + Output) rendered in a JS tab container. A new procd init.d service starts/stops sing-box and manages nftables. The Apply button calls an rpcd `restart` method instead of the old Generate flow. All server logic is ucode; Lua files are deleted.

**Tech Stack:** LuCI2 (form.Map, form.TypedSection, section.tab), ucode + ucode-mod-uci, procd init.d, nftables, sing-box, rpcd (shell), jq (tests)

---

## File Map

| File | Action |
|---|---|
| `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.lua` | Delete |
| `luci-app-singbox-ui/root/usr/share/singbox-ui/singbox_ui_config.lua` | Delete |
| `tests/test_generate_smoke.lua` | Delete |
| `tests/test_singbox_ui_config.lua` | Delete |
| `tests/helpers.lua` | Delete |
| `luci-app-singbox-ui/root/etc/config/singbox-ui` | Modify — remove nftables section, add example outbounds |
| `luci-app-singbox-ui/root/etc/init.d/singbox-ui` | **Create** — procd service |
| `luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui` | Modify — add restart method + SINGBOX_INIT env var |
| `luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json` | Modify — add restart to ubus |
| `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc` | Modify — UCI_CONFIG_DIR, outbounds, URL parser, routing |
| `luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js` | Rewrite — tabs, outbounds, Apply flow |
| `luci-app-singbox-ui/Makefile` | Modify — add init.d install |
| `tests/test_rpcd_handler.sh` | Modify — add restart coverage |
| `tests/test_generate.sh` | **Create** — ucode smoke tests (VM only, skips locally) |
| `tests/test_main_js_syntax.sh` | Modify — remove nftables/generate checks, add restart/outbound checks |

---

## Task 1: Delete Lua artifacts and update UCI config

**Files:**
- Delete: `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.lua`
- Delete: `luci-app-singbox-ui/root/usr/share/singbox-ui/singbox_ui_config.lua`
- Delete: `tests/test_generate_smoke.lua`
- Delete: `tests/test_singbox_ui_config.lua`
- Delete: `tests/helpers.lua`
- Modify: `luci-app-singbox-ui/root/etc/config/singbox-ui`

- [ ] **Step 1: Delete Lua files from repo**

```bash
git rm luci-app-singbox-ui/root/usr/share/singbox-ui/generate.lua \
       luci-app-singbox-ui/root/usr/share/singbox-ui/singbox_ui_config.lua \
       tests/test_generate_smoke.lua \
       tests/test_singbox_ui_config.lua \
       tests/helpers.lua
```

Expected: 5 files staged for deletion.

- [ ] **Step 2: Replace UCI config — remove nftables section, add example outbounds**

Replace the entire file `luci-app-singbox-ui/root/etc/config/singbox-ui` with:

```
config fakeip 'fakeip'
	option enabled '0'
	list inet4_range '198.18.0.0/15'
	list inet6_range 'fc00::/18'

config tproxy 'tproxy'
	option enabled '0'
	option interface 'br-lan'
	option port '7893'

config outbound 'direct_out'
	option action 'direct'

config outbound 'block_out'
	option action 'block'
```

- [ ] **Step 3: Verify tests still pass (Lua section silently skips, shell tests run)**

```bash
sh tests/run.sh
```

Expected: "==> Lua tests" prints with no test files found, shell tests pass, "All tests passed."

- [ ] **Step 4: Commit**

```bash
git add luci-app-singbox-ui/root/etc/config/singbox-ui
git commit -m "refactor: drop Lua artifacts, remove nftables UCI section"
```

---

## Task 2: Create procd init.d service

**Files:**
- Create: `luci-app-singbox-ui/root/etc/init.d/singbox-ui`

- [ ] **Step 1: Create the init.d script**

Create `luci-app-singbox-ui/root/etc/init.d/singbox-ui`:

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
	# sing-box does not support signal-based config reload.
	stop
	start
}
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x luci-app-singbox-ui/root/etc/init.d/singbox-ui
```

- [ ] **Step 3: shellcheck it**

```bash
shellcheck -s sh luci-app-singbox-ui/root/etc/init.d/singbox-ui
```

Expected: no output, exit 0. (shellcheck understands `/etc/rc.common` conventions; if it flags `USE_PROCD` etc., add `# shellcheck disable=SC2034` for those variables.)

- [ ] **Step 4: Update Makefile to install init.d**

In `luci-app-singbox-ui/Makefile`, add after the nftables.sh install block:

```makefile
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/singbox-ui $(1)/etc/init.d/singbox-ui
```

The full install section becomes:

```makefile
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/singbox-ui $(1)/etc/config/singbox-ui

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-luci-app-singbox-ui \
	  $(1)/etc/uci-defaults/99-luci-app-singbox-ui

	$(INSTALL_DIR) $(1)/etc/singbox-ui
	$(INSTALL_BIN) ./root/etc/singbox-ui/nftables.sh $(1)/etc/singbox-ui/nftables.sh

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./root/etc/init.d/singbox-ui $(1)/etc/init.d/singbox-ui

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/singbox-ui $(1)/usr/libexec/rpcd/singbox-ui

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-singbox-ui.json \
	  $(1)/usr/share/luci/menu.d/luci-app-singbox-ui.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json \
	  $(1)/usr/share/rpcd/acl.d/luci-app-singbox-ui.json

	$(INSTALL_DIR) $(1)/usr/share/singbox-ui
	$(INSTALL_DATA) ./root/usr/share/singbox-ui/generate.uc \
	  $(1)/usr/share/singbox-ui/generate.uc

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/singbox-ui
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/singbox-ui/main.js \
	  $(1)/www/luci-static/resources/view/singbox-ui/main.js
endef
```

- [ ] **Step 5: Commit**

```bash
git add luci-app-singbox-ui/root/etc/init.d/singbox-ui luci-app-singbox-ui/Makefile
git commit -m "feat: add procd init.d service for singbox-ui"
```

---

## Task 3: rpcd — add restart method with testable SINGBOX_INIT env var

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui`
- Modify: `tests/test_rpcd_handler.sh`

- [ ] **Step 1: Add SINGBOX_INIT to rpcd handler and add restart method**

Write the complete new `luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui`:

```sh
#!/bin/sh
# rpcd handler for singbox-ui. Methods:
#   generate        run /usr/share/singbox-ui/generate.uc
#   nftables {action}  run /etc/singbox-ui/nftables.sh apply|remove
#   restart         restart /etc/init.d/singbox-ui (full service restart)
#
# NFTABLES_SH, GENERATE_UC, SINGBOX_INIT env vars override paths (used by tests).

NFTABLES_SH=${NFTABLES_SH:-/etc/singbox-ui/nftables.sh}
GENERATE_UC=${GENERATE_UC:-/usr/share/singbox-ui/generate.uc}
SINGBOX_INIT=${SINGBOX_INIT:-/etc/init.d/singbox-ui}

emit_list() {
	cat <<'EOF'
{
	"generate": {},
	"nftables": { "action": "string" },
	"restart": {}
}
EOF
}

emit_ok() {
	printf '{"status":"ok"}\n'
}

emit_err() {
	msg=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
	printf '{"status":"error","message":"%s"}\n' "$msg"
}

read_action() {
	if command -v jq >/dev/null 2>&1; then
		jq -r '.action // empty'
	else
		grep -oE '"action"[[:space:]]*:[[:space:]]*"[^"]*"' \
			| sed -E 's/.*"([^"]*)"$/\1/' \
			| head -n1
	fi
}

case "${1:-}" in
list)
	emit_list
	;;
call)
	method="${2:-}"
	case "$method" in
	generate)
		cat >/dev/null
		if ucode "$GENERATE_UC" >/dev/null; then
			emit_ok
		else
			emit_err "generate.uc failed"
		fi
		;;
	nftables)
		action=$(read_action)
		case "$action" in
		apply|remove)
			if "$NFTABLES_SH" "$action" >/dev/null; then
				emit_ok
			else
				emit_err "nftables.sh $action failed"
			fi
			;;
		*)
			emit_err "invalid action: ${action:-<missing>}"
			;;
		esac
		;;
	restart)
		cat >/dev/null
		if "$SINGBOX_INIT" restart >/dev/null 2>&1; then
			emit_ok
		else
			emit_err "service restart failed"
		fi
		;;
	*)
		emit_err "unknown method: $method"
		;;
	esac
	;;
*)
	echo "Usage: $0 {list|call <method>}" >&2
	exit 1
	;;
esac
```

- [ ] **Step 2: Write the failing test for restart (before confirming it passes)**

Add to end of `tests/test_rpcd_handler.sh` (before the final `echo "OK"`):

```sh
echo "-- list includes restart method"
out=$("$H" list)
echo "$out" | jq -e '.restart' >/dev/null || { echo "FAIL: missing restart in list"; exit 1; }

echo "-- call restart with stubbed init.d returns ok"
out=$(echo '{}' | SINGBOX_INIT=true "$H" call restart)
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: restart with stub did not return ok"; exit 1; }

echo "-- call restart with failing init.d returns error"
out=$(echo '{}' | SINGBOX_INIT=false "$H" call restart)
echo "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: failing restart should return error"; exit 1; }
```

(`true` and `false` are standard Unix commands that exit 0 and 1 respectively — perfect stubs.)

- [ ] **Step 3: Run the test to verify it passes**

```bash
sh tests/test_rpcd_handler.sh
```

Expected: all checks pass including the three new restart assertions. "OK" at the end.

- [ ] **Step 4: Commit**

```bash
git add luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui tests/test_rpcd_handler.sh
git commit -m "feat: add rpcd restart method with SINGBOX_INIT override"
```

---

## Task 4: Update ACL to allow restart

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json`

- [ ] **Step 1: Add restart to ubus permissions**

Write the complete new `luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json`:

```json
{
	"luci-app-singbox-ui": {
		"description": "Grant LuCI access to singbox-ui",
		"read": {
			"uci": [ "singbox-ui" ],
			"ubus": {
				"singbox-ui": [ "generate", "nftables", "restart" ]
			}
		},
		"write": {
			"uci": [ "singbox-ui" ]
		}
	}
}
```

- [ ] **Step 2: Verify shell tests still pass**

```bash
sh tests/run.sh
```

Expected: "All tests passed."

- [ ] **Step 3: Commit**

```bash
git add luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json
git commit -m "feat: add restart to rpcd ACL"
```

---

## Task 5: generate.uc — UCI_CONFIG_DIR env var support

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc`

- [ ] **Step 1: Add UCI_CONFIG_DIR support to generate.uc**

Change the top of `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc` from:

```js
let uci = require("uci").cursor();
let fs  = require("fs");
```

to:

```js
let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");
```

The full file at this point:

```js
#!/usr/bin/ucode
// Read UCI config and write /tmp/singbox-ui.json for sing-box.

let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");

function get_bool(section, opt) {
	return uci.get("singbox-ui", section, opt) === "1";
}

function get_list(section, opt) {
	let all = uci.get_all("singbox-ui", section);
	return (all != null) ? (all[opt] ?? []) : [];
}

// Produce indented JSON (4-space indent).
function indent_of(depth) {
	let s = "";
	for (let i = 0; i < depth; i++) s += "    ";
	return s;
}

function to_json(val, depth) {
	if (depth == null) depth = 0;
	let t = type(val);

	if (t === "object") {
		let ks = keys(val);
		if (!length(ks)) return "{}";
		let inner = indent_of(depth + 1);
		let outer = indent_of(depth);
		let parts = [];
		for (let k in ks)
			push(parts, inner + sprintf("%J", k) + ": " + to_json(val[k], depth + 1));
		return "{\n" + join(",\n", parts) + "\n" + outer + "}";
	}

	if (t === "array") {
		if (!length(val)) return "[]";
		let inner = indent_of(depth + 1);
		let outer = indent_of(depth);
		let parts = [];
		for (let v in val)
			push(parts, inner + to_json(v, depth + 1));
		return "[\n" + join(",\n", parts) + "\n" + outer + "]";
	}

	return sprintf("%J", val);
}

let config = {};

if (get_bool("fakeip", "enabled")) {
	config.dns = {
		fakeip: {
			enabled: true,
			inet4_range: get_list("fakeip", "inet4_range"),
			inet6_range: get_list("fakeip", "inet6_range"),
		},
	};
}

if (get_bool("tproxy", "enabled")) {
	let port = +(uci.get("singbox-ui", "tproxy", "port") ?? "7893") || 7893;
	config.inbounds = [ {
		type: "tproxy",
		listen: "::",
		listen_port: port,
	} ];
}

let f = fs.open("/tmp/singbox-ui.json", "w");
if (!f) {
	warn("generate.uc: cannot open /tmp/singbox-ui.json for writing\n");
	exit(1);
}
f.write(to_json(config) + "\n");
f.close();

print("OK\n");
```

- [ ] **Step 2: Commit**

```bash
git add luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
git commit -m "feat: generate.uc supports UCI_CONFIG_DIR env var for testing"
```

---

## Task 6: generate.uc — outbounds (direct, block, interface)

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc`

- [ ] **Step 1: Add outbound generation function to generate.uc**

Add the `build_outbounds_and_routes()` function before the `let config = {};` line. This task implements direct/block/interface outbounds only (URL parser comes in Task 7, routing in Task 8).

Add after the `to_json` function:

```js
function build_outbounds_and_routes() {
	let outbounds = [];
	let route_rules = [];
	let route_rule_sets = [];

	uci.foreach("singbox-ui", "outbound", function(section) {
		let name = section[".name"];
		let action = section.action;
		let outbound = null;

		if (action === "direct") {
			outbound = { tag: name, type: "direct" };
		} else if (action === "block") {
			outbound = { tag: name, type: "block" };
		} else if (action === "proxy") {
			let proxy_type = section.proxy_type;
			if (proxy_type === "interface") {
				outbound = { tag: name, type: "direct", bind_interface: section.interface };
			} else if (proxy_type === "url") {
				// URL parsing added in next task; skip for now
				warn("generate.uc: proxy url not yet supported for section: " + name + "\n");
			}
		}

		if (outbound) push(outbounds, outbound);
	});

	return { outbounds, route_rules, route_rule_sets };
}
```

Then replace the section after `config.inbounds = ...` block (before `let f = fs.open...`) with:

```js
let result = build_outbounds_and_routes();
let outbounds = result.outbounds;
let route_rules = result.route_rules;
let route_rule_sets = result.route_rule_sets;

if (length(outbounds)) config.outbounds = outbounds;
if (length(route_rules)) {
	config.route = { rules: route_rules };
	if (length(route_rule_sets)) config.route.rule_set = route_rule_sets;
}
```

- [ ] **Step 2: Verify syntax (run on dev machine)**

```bash
sh tests/test_main_js_syntax.sh
sh tests/run.sh
```

Expected: all tests pass. (generate.uc syntax errors would show during other tests if shellcheck also checks it — but generate.uc is ucode not shell, so only runtime catches syntax errors.)

- [ ] **Step 3: Commit**

```bash
git add luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
git commit -m "feat: generate.uc iterates outbound sections (direct/block/interface)"
```

---

## Task 7: generate.uc — URL parser (vless, hy2/hysteria2)

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc`

- [ ] **Step 1: Add URL parser functions to generate.uc**

Add these three functions after the `to_json` function, before `build_outbounds_and_routes`:

```js
function parse_query(query_string) {
	let params = {};
	for (let part in split(query_string, "&")) {
		let eq = index(part, "=");
		if (eq < 0) continue;
		let k = substr(part, 0, eq);
		let v = substr(part, eq + 1);
		params[k] = v;
	}
	return params;
}

function parse_vless(url) {
	// vless://uuid@host:port?params
	let m = match(url, /^vless:\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?/);
	if (!m) return null;
	let uuid = m[1];
	let host = m[2];
	let port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};

	let out = {
		type: "vless",
		server: host,
		server_port: port,
		uuid: uuid,
	};

	let security = params["security"];
	if (security === "tls" || security === "reality") {
		let sni = params["sni"] ?? host;
		out.tls = { enabled: true, server_name: sni };
		if (params["fp"])
			out.tls.utls = { enabled: true, fingerprint: params["fp"] };
		if (security === "reality" && params["pbk"])
			out.tls.reality = { enabled: true, public_key: params["pbk"] };
	}

	let transport_type = params["type"];
	if (transport_type && transport_type !== "tcp")
		out.transport = { type: transport_type };

	return out;
}

function parse_hy2(url) {
	// hy2://password@host:port?params  (also hysteria2://)
	let m = match(url, /^(?:hy2|hysteria2):\/\/([^@]+)@([^:/?#]+):([0-9]+)(\?[^#]*)?/);
	if (!m) return null;
	let password = m[1];
	let host = m[2];
	let port = +m[3];
	let params = m[4] ? parse_query(substr(m[4], 1)) : {};

	let out = {
		type: "hysteria2",
		server: host,
		server_port: port,
		password: password,
		tls: { enabled: true, server_name: params["sni"] ?? host },
	};

	if (params["obfs"] === "salamander") {
		out.obfs = { type: "salamander", password: params["obfs-password"] ?? "" };
	}

	return out;
}

function parse_proxy_url(url) {
	if (match(url, /^vless:\/\//))              return parse_vless(url);
	if (match(url, /^(?:hy2|hysteria2):\/\//)) return parse_hy2(url);
	warn("generate.uc: unsupported proxy URL scheme: " + url + "\n");
	return null;
}
```

- [ ] **Step 2: Update build_outbounds_and_routes to use URL parser**

Replace the `proxy_type === "url"` branch inside `build_outbounds_and_routes`:

```js
} else if (proxy_type === "url") {
    let parsed = parse_proxy_url(section.proxy_url ?? "");
    if (parsed) {
        parsed.tag = name;
        outbound = parsed;
    }
}
```

- [ ] **Step 3: Run shell tests to verify no regressions**

```bash
sh tests/run.sh
```

Expected: "All tests passed."

- [ ] **Step 4: Commit**

```bash
git add luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
git commit -m "feat: generate.uc URL parser for vless:// and hy2:// proxy links"
```

---

## Task 8: generate.uc — routing rules from Conditions

**Files:**
- Modify: `luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc`

- [ ] **Step 1: Add routing rule generation inside build_outbounds_and_routes**

After the `if (outbound) push(outbounds, outbound);` line (and the `else return;` should become the guard), add the condition-to-routing-rule logic.

Replace the `build_outbounds_and_routes` function body entirely with this version (includes everything from Task 6 + routing logic):

```js
function build_outbounds_and_routes() {
	let outbounds = [];
	let route_rules = [];
	let route_rule_sets = [];

	uci.foreach("singbox-ui", "outbound", function(section) {
		let name = section[".name"];
		let action = section.action;
		let outbound = null;

		if (action === "direct") {
			outbound = { tag: name, type: "direct" };
		} else if (action === "block") {
			outbound = { tag: name, type: "block" };
		} else if (action === "proxy") {
			let proxy_type = section.proxy_type;
			if (proxy_type === "interface") {
				outbound = { tag: name, type: "direct", bind_interface: section.interface };
			} else if (proxy_type === "url") {
				let parsed = parse_proxy_url(section.proxy_url ?? "");
				if (parsed) {
					parsed.tag = name;
					outbound = parsed;
				}
			}
		}

		if (!outbound) return;
		push(outbounds, outbound);

		// Build routing rule from Conditions tab fields.
		let rulesets = section.ruleset ?? [];
		if (type(rulesets) === "string") rulesets = [ rulesets ];
		let domains = section.domain ?? [];
		if (type(domains) === "string") domains = [ domains ];

		if (!length(rulesets) && !length(domains)) return;

		let rule = { outbound: name };
		let rs_tags = [];

		for (let i, rs in rulesets) {
			let rs_tag = "rs_" + name + "_" + i;
			let is_local = (substr(rs, 0, 1) === "/");
			let format = match(rs, /\.srs$/) ? "binary" : "source";
			let rs_obj;
			if (is_local) {
				rs_obj = { tag: rs_tag, type: "local", format: format, path: rs };
			} else {
				rs_obj = { tag: rs_tag, type: "remote", format: format, url: rs };
			}
			push(route_rule_sets, rs_obj);
			push(rs_tags, rs_tag);
		}

		if (length(rs_tags)) rule.rule_set = rs_tags;
		if (length(domains)) rule.domain_suffix = domains;

		push(route_rules, rule);
	});

	return { outbounds, route_rules, route_rule_sets };
}
```

- [ ] **Step 2: Run shell tests**

```bash
sh tests/run.sh
```

Expected: "All tests passed."

- [ ] **Step 3: Commit**

```bash
git add luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
git commit -m "feat: generate.uc builds route.rules and route.rule_set from outbound conditions"
```

---

## Task 9: Create test_generate.sh (VM smoke tests)

**Files:**
- Create: `tests/test_generate.sh`

- [ ] **Step 1: Write test_generate.sh**

Create `tests/test_generate.sh`:

```sh
#!/bin/sh
# tests/test_generate.sh
# Smoke-tests generate.uc end-to-end. Requires ucode + ucode-mod-uci.
# Skips automatically on dev machines where ucode is unavailable.
set -e

command -v ucode >/dev/null 2>&1 || { echo "SKIP: ucode not available"; exit 0; }

GENERATE_UC=luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

check() {
	desc="$1"; pattern="$2"; file="$3"
	grep -q "$pattern" "$file" \
		|| { echo "FAIL: $desc — '$pattern' not found in $file"; cat "$file"; exit 1; }
	echo "  PASS: $desc"
}

write_cfg() { printf '%s\n' "$1" > "$TMPDIR/singbox-ui"; }

run_gen() { UCI_CONFIG_DIR="$TMPDIR" ucode "$GENERATE_UC" > "$TMPDIR/out.json"; }

# ---- fakeip + tproxy ----
echo "-- fakeip and tproxy inbound"
write_cfg "
config fakeip 'fakeip'
	option enabled '1'
	list inet4_range '198.18.0.0/15'
	list inet6_range 'fc00::/18'

config tproxy 'tproxy'
	option enabled '1'
	option port '7893'
"
run_gen
check "fakeip enabled"   '"enabled": true'         "$TMPDIR/out.json"
check "inet4_range"      '"198.18.0.0/15"'          "$TMPDIR/out.json"
check "tproxy inbound"   '"type": "tproxy"'         "$TMPDIR/out.json"
check "listen_port 7893" '"listen_port": 7893'      "$TMPDIR/out.json"

# ---- direct outbound ----
echo "-- direct outbound"
write_cfg "
config outbound 'direct_out'
	option action 'direct'
"
run_gen
check "direct tag"  '"tag": "direct_out"' "$TMPDIR/out.json"
check "direct type" '"type": "direct"'    "$TMPDIR/out.json"

# ---- block outbound ----
echo "-- block outbound"
write_cfg "
config outbound 'block_out'
	option action 'block'
"
run_gen
check "block tag"  '"tag": "block_out"' "$TMPDIR/out.json"
check "block type" '"type": "block"'    "$TMPDIR/out.json"

# ---- proxy via interface ----
echo "-- proxy via interface"
write_cfg "
config outbound 'via_wg0'
	option action 'proxy'
	option proxy_type 'interface'
	option interface 'wg0'
"
run_gen
check "interface proxy tag"  '"tag": "via_wg0"'        "$TMPDIR/out.json"
check "bind_interface"       '"bind_interface": "wg0"'  "$TMPDIR/out.json"

# ---- vless URL ----
echo "-- vless:// URL"
write_cfg "
config outbound 'my_vless'
	option action 'proxy'
	option proxy_type 'url'
	option proxy_url 'vless://test-uuid-1234@example.com:443?security=tls&sni=example.com&type=tcp'
"
run_gen
check "vless type"   '"type": "vless"'          "$TMPDIR/out.json"
check "vless uuid"   '"uuid": "test-uuid-1234"' "$TMPDIR/out.json"
check "vless server" '"server": "example.com"'  "$TMPDIR/out.json"
check "vless port"   '"server_port": 443'        "$TMPDIR/out.json"
check "vless tls"    '"enabled": true'           "$TMPDIR/out.json"

# ---- hy2 URL ----
echo "-- hy2:// URL"
write_cfg "
config outbound 'my_hy2'
	option action 'proxy'
	option proxy_type 'url'
	option proxy_url 'hy2://mypassword@vpn.example.com:8443?sni=vpn.example.com'
"
run_gen
check "hy2 type"     '"type": "hysteria2"'         "$TMPDIR/out.json"
check "hy2 password" '"password": "mypassword"'    "$TMPDIR/out.json"
check "hy2 server"   '"server": "vpn.example.com"' "$TMPDIR/out.json"

# ---- routing rules ----
echo "-- routing rules from conditions"
write_cfg "
config outbound 'routed'
	option action 'direct'
	list ruleset 'https://example.com/rules.srs'
	list ruleset '/etc/singbox-ui/local.json'
	list domain 'google.com'
	list domain 'youtube.com'
"
run_gen
check "route rules"      '"rules":'           "$TMPDIR/out.json"
check "rule_set tag 0"   '"rs_routed_0"'      "$TMPDIR/out.json"
check "rule_set tag 1"   '"rs_routed_1"'      "$TMPDIR/out.json"
check "remote ruleset"   '"type": "remote"'   "$TMPDIR/out.json"
check "local ruleset"    '"type": "local"'    "$TMPDIR/out.json"
check "binary format"    '"format": "binary"' "$TMPDIR/out.json"
check "source format"    '"format": "source"' "$TMPDIR/out.json"
check "domain_suffix"    '"domain_suffix":'   "$TMPDIR/out.json"
check "google.com"       '"google.com"'       "$TMPDIR/out.json"

echo "OK"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x tests/test_generate.sh
```

- [ ] **Step 3: Run locally (expect SKIP)**

```bash
sh tests/test_generate.sh
```

Expected output: `SKIP: ucode not available`

- [ ] **Step 4: Run the full test suite**

```bash
sh tests/run.sh
```

Expected: "All tests passed." (test_generate.sh skips gracefully).

- [ ] **Step 5: Commit**

```bash
git add tests/test_generate.sh
git commit -m "test: add test_generate.sh smoke tests (runs on VM, skips locally)"
```

---

## Task 10: Update test_main_js_syntax.sh for new UI shape

The current syntax test checks for `nftables` section, `generate` and `nftables` rpc bindings — all of which are removed in Phase 2. Update the test first (TDD: failing test → implementation).

**Files:**
- Modify: `tests/test_main_js_syntax.sh`

- [ ] **Step 1: Verify current test passes before touching anything**

```bash
sh tests/test_main_js_syntax.sh
```

Expected: "OK" (current main.js still has nftables etc.)

- [ ] **Step 2: Write the updated test_main_js_syntax.sh**

Write the complete new `tests/test_main_js_syntax.sh`:

```sh
#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js

if [ ! -f "$JS" ]; then
  echo "FAIL: $JS not present"; exit 1
fi

# LuCI views are fragments — top-level `return` is invalid in standalone JS.
# Wrap them in a function for syntax checking.
tmp=$(mktemp --suffix=.js)
{
  echo "(function () {"
  cat "$JS"
  echo "});"
} > "$tmp"

if ! node --check "$tmp"; then
  echo "FAIL: JS syntax error"; rm -f "$tmp"; exit 1
fi
rm -f "$tmp"

echo "-- declares all expected requires"
grep -q "'require view'"    "$JS" || { echo "FAIL: missing 'require view'"; exit 1; }
grep -q "'require form'"    "$JS" || { echo "FAIL: missing 'require form'"; exit 1; }
grep -q "'require uci'"     "$JS" || { echo "FAIL: missing 'require uci'"; exit 1; }
grep -q "'require rpc'"     "$JS" || { echo "FAIL: missing 'require rpc'"; exit 1; }
grep -q "'require ui'"      "$JS" || { echo "FAIL: missing 'require ui'"; exit 1; }
grep -q "'require network'" "$JS" || { echo "FAIL: missing 'require network'"; exit 1; }

echo "-- references input UCI sections"
grep -q "fakeip"   "$JS" || { echo "FAIL: no fakeip section"; exit 1; }
grep -q "tproxy"   "$JS" || { echo "FAIL: no tproxy section"; exit 1; }

echo "-- references outbound TypedSection"
grep -q "outbound" "$JS" || { echo "FAIL: no outbound TypedSection"; exit 1; }

echo "-- wires the restart rpc method"
grep -q "singbox-ui.*restart" "$JS" || { echo "FAIL: no restart rpc binding"; exit 1; }

echo "-- has handleSaveApply"
grep -q "handleSaveApply" "$JS" || { echo "FAIL: no handleSaveApply"; exit 1; }

echo "OK"
```

- [ ] **Step 3: Run updated test — expect FAIL (old main.js doesn't match new expectations)**

```bash
sh tests/test_main_js_syntax.sh
```

Expected: FAIL on "no outbound TypedSection" or "no restart rpc binding" — confirms the test is guarding the new behavior.

- [ ] **Step 4: Commit the updated test**

```bash
git add tests/test_main_js_syntax.sh
git commit -m "test: update main.js syntax test for Phase 2 UI shape"
```

---

## Task 11: main.js — complete rewrite (tabs, Input + Output, Apply flow)

**Files:**
- Modify: `luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js`

- [ ] **Step 1: Rewrite main.js**

Write the complete new `luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js`:

```js
'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require network';

var callRestart = rpc.declare({
	object: 'singbox-ui',
	method: 'restart',
	expect: { status: 'error' }
});

return view.extend({
	load: function () {
		return Promise.all([
			network.getDevices(),
			uci.load('singbox-ui')
		]);
	},

	render: function (data) {
		var self = this;
		var devices = data[0];

		// ---- Input form ----
		var mInput = new form.Map('singbox-ui', _('Input'),
			_('Configure FakeIP and TProxy inbound. ' +
			  'nftables redirect rules are applied automatically ' +
			  'when TProxy is enabled and the service starts.'));

		var s, o;

		// FakeIP
		s = mInput.section(form.NamedSection, 'fakeip', 'fakeip', _('FakeIP'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'inet4_range', _('IPv4 ranges'));
		o.datatype = 'cidr4';
		o.placeholder = '198.18.0.0/15';

		o = s.option(form.DynamicList, 'inet6_range', _('IPv6 ranges'));
		o.datatype = 'cidr6';
		o.placeholder = 'fc00::/18';

		// TProxy
		s = mInput.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'interface', _('Interface'));
		(devices || []).forEach(function (d) {
			var name = d.getName();
			if (name) o.value(name, name);
		});

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '7893';

		// ---- Output form ----
		var mOutput = new form.Map('singbox-ui', _('Output'),
			_('Add, configure, and remove outbounds. ' +
			  'Each outbound can have routing conditions (rule sets and domains).'));

		s = mOutput.section(form.TypedSection, 'outbound', _('Outbounds'));
		s.anonymous = false;
		s.addremove = true;

		s.tab('settings', _('Settings'));
		s.tab('conditions', _('Conditions'));

		o = s.taboption('settings', form.ListValue, 'action', _('Action'));
		o.value('direct', _('Direct'));
		o.value('block', _('Block'));
		o.value('proxy', _('Proxy'));
		o.rmempty = false;

		o = s.taboption('settings', form.ListValue, 'proxy_type', _('Type'));
		o.value('interface', _('Interface'));
		o.value('url', _('URL (share link)'));
		o.depends('action', 'proxy');

		o = s.taboption('settings', form.ListValue, 'interface', _('Interface'));
		(devices || []).forEach(function (d) {
			var name = d.getName();
			if (name) o.value(name, name);
		});
		o.depends({ action: 'proxy', proxy_type: 'interface' });

		o = s.taboption('settings', form.Value, 'proxy_url', _('URL'));
		o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
		o.depends({ action: 'proxy', proxy_type: 'url' });

		o = s.taboption('conditions', form.DynamicList, 'ruleset', _('Rule sets'));
		o.placeholder = 'https://example.com/geosite.srs  or  /etc/singbox-ui/rules.json';

		o = s.taboption('conditions', form.DynamicList, 'domain', _('Domains'));
		o.placeholder = 'example.com';

		self._mInput  = mInput;
		self._mOutput = mOutput;

		return Promise.all([ mInput.render(), mOutput.render() ]).then(function (nodes) {
			var inputNode  = nodes[0];
			var outputNode = nodes[1];

			outputNode.style.display = 'none';

			function switchTab(ev) {
				var tab = ev.currentTarget.getAttribute('data-tab');
				document.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.classList.toggle('cbi-tab-active', el.getAttribute('data-tab') === tab);
				});
				inputNode.style.display  = (tab === 'input')  ? '' : 'none';
				outputNode.style.display = (tab === 'output') ? '' : 'none';
			}

			return E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', {
						'class': 'cbi-tab-active',
						'data-tab': 'input',
						'click': switchTab
					}, _('Input')),
					E('li', {
						'class': 'cbi-tab',
						'data-tab': 'output',
						'click': switchTab
					}, _('Output'))
				]),
				inputNode,
				outputNode
			]);
		});
	},

	handleSave: function (ev) {
		return Promise.all([
			this._mInput.save(),
			this._mOutput.save()
		]);
	},

	handleSaveApply: function (ev) {
		var self = this;
		return self.handleSave(ev).then(function () {
			return callRestart().then(function (status) {
				if (!status || status === 'ok') {
					ui.addNotification(null,
						E('p', _('Service restarted successfully.')),
						'info');
				} else {
					ui.addNotification(null,
						E('p', _('Restart failed: %s').format(String(status))),
						'danger');
				}
			});
		});
	},

	handleApply: null,
	handleReset: null
});
```

- [ ] **Step 2: Run syntax test**

```bash
sh tests/test_main_js_syntax.sh
```

Expected: passes (no syntax errors). Requires `node` — install with `npm` or your distro package manager if missing.

- [ ] **Step 3: Run full test suite**

```bash
sh tests/run.sh
```

Expected: "All tests passed."

- [ ] **Step 4: Commit**

```bash
git add luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js
git commit -m "feat: rewrite main.js — tabbed UI, outbounds Output tab, Apply restart flow"
```

---

## Task 12: Deploy to OpenWrt VM and run integration tests

**VM:** 192.168.100.145, root / admin  
**Prerequisite:** sing-box must be installed on the VM (`opkg install sing-box`). Disable the upstream sing-box init.d to avoid conflicts: `service sing-box disable && service sing-box stop`.

- [ ] **Step 1: Copy all changed files to VM**

```bash
VM=root@192.168.100.145

scp luci-app-singbox-ui/root/etc/config/singbox-ui \
    "$VM:/etc/config/singbox-ui"

scp luci-app-singbox-ui/root/etc/init.d/singbox-ui \
    "$VM:/etc/init.d/singbox-ui"

scp luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui \
    "$VM:/usr/libexec/rpcd/singbox-ui"

scp luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json \
    "$VM:/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"

scp luci-app-singbox-ui/root/usr/share/singbox-ui/generate.uc \
    "$VM:/usr/share/singbox-ui/generate.uc"

scp luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js \
    "$VM:/www/luci-static/resources/view/singbox-ui/main.js"

scp tests/test_generate.sh "$VM:/tmp/test_generate.sh"
```

- [ ] **Step 2: Set permissions on VM**

```bash
ssh root@192.168.100.145 "
  chmod +x /etc/init.d/singbox-ui
  chmod +x /usr/libexec/rpcd/singbox-ui
  chmod +x /usr/share/singbox-ui/generate.uc
  /etc/init.d/rpcd reload
"
```

- [ ] **Step 3: Run generate.uc smoke tests on VM**

```bash
ssh root@192.168.100.145 "cd / && sh /tmp/test_generate.sh"
```

Expected: all PASS lines then "OK". If any FAIL — inspect `/tmp/singbox-ui.json` and the error output.

- [ ] **Step 4: Test service start/stop**

```bash
ssh root@192.168.100.145 "
  # Enable tproxy so nftables rules are applied on start
  uci set singbox-ui.tproxy.enabled=1
  uci set singbox-ui.tproxy.interface=br-lan
  uci set singbox-ui.tproxy.port=7893
  uci set singbox-ui.fakeip.enabled=1
  uci commit singbox-ui

  echo '=== start service ==='
  /etc/init.d/singbox-ui start
  sleep 1

  echo '=== nftables table should exist ==='
  nft list table inet singbox_ui

  echo '=== generated config should exist ==='
  cat /tmp/singbox-ui.json

  echo '=== stop service ==='
  /etc/init.d/singbox-ui stop
  sleep 1

  echo '=== nftables table should be gone ==='
  nft list table inet singbox_ui 2>&1 || echo 'PASS: table removed'
"
```

Expected:
- After start: `nft list table inet singbox_ui` shows the table with two chains
- After stop: command fails with "No such file or directory" or similar → "PASS: table removed"

- [ ] **Step 5: Test rpcd restart method**

```bash
ssh root@192.168.100.145 "
  /etc/init.d/singbox-ui start
  echo '{}' | /usr/libexec/rpcd/singbox-ui call restart
"
```

Expected: `{"status":"ok"}`

- [ ] **Step 6: Verify LuCI UI loads in browser**

Open `http://192.168.100.145` in a browser. Navigate to Services → Singbox-UI. Verify:
- Two tabs appear: Input and Output
- Input tab shows FakeIP and TProxy sections (no nftables section)
- Output tab shows outbound list with Add button
- Clicking Add creates a new outbound with Settings/Conditions sub-tabs
- Settings sub-tab: action dropdown shows block/direct/proxy; selecting proxy shows proxy_type; selecting url shows URL field
- Conditions sub-tab: ruleset and domain DynamicLists
- Save & Apply button triggers service restart and shows notification

- [ ] **Step 7: Add a vless outbound via UI and verify generated config**

In the LuCI UI:
1. Go to Output tab → Add a new outbound named `my_vless`
2. Action: proxy, Type: url
3. URL: `vless://test-uuid@example.com:443?security=tls&sni=example.com`
4. Conditions: add domain `google.com`
5. Click Save & Apply

Then verify:

```bash
ssh root@192.168.100.145 "cat /tmp/singbox-ui.json"
```

Expected JSON contains:
- `"type": "vless"` with `"uuid": "test-uuid"`, `"server": "example.com"`
- `"route"` section with `"rules"` containing `"domain_suffix": ["google.com"]`

- [ ] **Step 8: Commit if any last-minute fixes were needed on VM**

If any bugs were found and fixed during VM testing, commit those fixes:

```bash
git add -p  # stage only intentional changes
git commit -m "fix: <describe what was fixed during VM integration test>"
```

---

## Final checklist

- [ ] `sh tests/run.sh` passes on dev machine
- [ ] `sh tests/test_generate.sh` passes on VM  
- [ ] Service start/stop correctly manages nftables and sing-box
- [ ] LuCI UI shows Input/Output tabs with all fields working
- [ ] Apply button restarts service and shows notification
- [ ] Generated JSON includes outbounds and routing rules when configured
- [ ] No Lua files remain in the repo
