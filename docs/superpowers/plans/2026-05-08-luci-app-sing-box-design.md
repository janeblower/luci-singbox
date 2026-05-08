# luci-app-sing-box — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a LuCI application for OpenWrt 25 (LuCI2 / modern JS) that stores sing-box configuration knobs in UCI and generates a sing-box JSON config from them. First iteration: FakeIP, TProxy inbound, nftables rules, JSON dump to `/tmp/sing-box.json`.

**Architecture:** OpenWrt package layout. Settings live in UCI (`/etc/config/sing-box`). A Lua script (`generate.lua`) reads UCI and writes the JSON config. A POSIX shell script (`nftables.sh`) applies/removes nft rules. Browser code talks to backend through rpcd methods (`sing-box.generate`, `sing-box.nftables`); shell access never leaves rpcd. The LuCI view (`main.js`) is a single page with three sections plus a Generate button.

**Tech Stack:** OpenWrt build system, UCI, LuCI2 (JS modules in `htdocs/luci-static/resources/view/...`), Lua 5.1 (`uci` C-binding, `luci.jsonc`), POSIX shell, nftables, rpcd / ubus.

---

## Background notes (read before starting)

- **OpenWrt source layout convention.** Files under `root/` in the source mirror the target rootfs: `root/etc/config/sing-box` ships to `/etc/config/sing-box` on the device. The Makefile uses `INSTALL_DIR`/`INSTALL_BIN`/`INSTALL_DATA` to copy them.
- **UCI lists vs options.** `option foo 'bar'` is a single value. `list foo 'bar'` declares a list value; multiple `list` lines build a multi-element list. From shell, `uci get sing-box.fakeip.inet4_range` returns list elements space-separated. From Lua, `cursor:get_list("sing-box","fakeip","inet4_range")` returns a Lua array.
- **LuCI2 view modules.** A view file is a JS module loaded by LuCI's AMD-style runtime. Top-level `'require X';` strings are recognised by LuCI's loader and the file ends with a top-level `return view.extend({...})`. This is *not* valid standalone JS — `node --check` on the raw file will fail. To syntax-check it locally, wrap it in `(function(){ ... })();` first.
- **rpcd handler contract.** A handler at `/usr/libexec/rpcd/<name>` is invoked by ubus. `<name> list` prints a JSON object describing methods + arg schemas. `<name> call <method>` is invoked with method args as a JSON object on stdin and must print a JSON result on stdout. Use `/usr/share/libubox/jshn.sh` for JSON in shell.
- **rpcd ACL.** `/usr/share/rpcd/acl.d/luci-app-sing-box.json` declares a role; methods listed under `write.ubus.<service>` become callable to authenticated LuCI users with that ACL. The LuCI menu's `depends.acl` ties the page visibility to the same ACL name.
- **nftables sets in plain shell.** `nft` accepts inline sets like `{ 1.2.3.0/24, 5.6.7.8 }`. From a UCI list, convert space-separated values to comma-separated for the `{ ... }` set.
- **Lua module path on OpenWrt.** `/usr/share/sing-box/` is not on `package.path` by default. The entrypoint `generate.lua` prepends it before `require`-ing the helper module.
- **Local test harness.** All Lua test files live under `tests/` at repo root. Run with `lua5.1 tests/<name>.lua`. Tests stub the OpenWrt-only modules (`uci`, `luci.jsonc`) via `package.preload`. Helper module `tests/helpers.lua` provides `assert_deep_equal` and a fake UCI cursor. `tests/run.sh` runs all of them.

---

## File map

Source repo layout produced by this plan:

```
luci-app-sing-box/
├── Makefile
├── htdocs/luci-static/resources/view/sing-box/main.js
├── root/
│   ├── etc/
│   │   ├── config/sing-box
│   │   ├── uci-defaults/99-luci-app-sing-box
│   │   └── sing-box/nftables.sh
│   └── usr/
│       ├── libexec/rpcd/sing-box
│       └── share/
│           ├── luci/menu.d/luci-app-sing-box.json
│           ├── rpcd/acl.d/luci-app-sing-box.json
│           └── sing-box/
│               ├── generate.lua
│               └── sing_box_config.lua
└── tests/
    ├── helpers.lua
    ├── test_sing_box_config.lua
    ├── test_generate_smoke.lua
    ├── test_nftables_emit.sh
    ├── test_rpcd_handler.sh
    ├── test_main_js_syntax.sh
    └── run.sh
```

**Responsibility split:**

- `sing_box_config.lua` — pure Lua module. `read_uci(cursor)` extracts a plain Lua state table from UCI. `build_config(state)` turns the state into the sing-box JSON-shaped Lua table. No I/O. Fully unit-testable.
- `generate.lua` — entrypoint. Glues `require"uci".cursor()` + `require"luci.jsonc"` + `sing_box_config` and writes `/tmp/sing-box.json`. Thin.
- `nftables.sh` — three subcommands: `emit <port> <v4_set> <v6_set>` prints rules to stdout (testable); `apply` reads UCI and pipes `emit` into `nft -f -`; `remove` deletes the table.
- `/usr/libexec/rpcd/sing-box` — rpcd handler. Wraps the two backend scripts as ubus methods.
- `main.js` — LuCI2 view. Three form sections + a Generate button. On save: if `nftables.enabled` flips, calls `sing-box.nftables` with `apply` or `remove`. Generate button calls `sing-box.generate`.

---

## Self-review checklist (run after writing code, before commit)

For each task, the engineer should verify:

1. The exact tests listed in the task pass.
2. No placeholder strings (`TBD`, `TODO`, `FIXME`) in the code.
3. File modes: shell scripts and rpcd handler are `chmod +x`.
4. Names match across files: ACL name `luci-app-sing-box`, ubus service `sing-box`, methods `generate`/`nftables`, LuCI menu path `admin/services/sing-box`, view path `sing-box/main`.

---

## Task 1: Repo bootstrap — test harness, Makefile, LuCI menu

**Files:**
- Create: `tests/helpers.lua`
- Create: `tests/run.sh`
- Create: `Makefile`
- Create: `root/usr/share/luci/menu.d/luci-app-sing-box.json`

- [ ] **Step 1: Write the test helper module**

```lua
-- tests/helpers.lua
local M = {}

-- Deep equality for tables (order-sensitive for arrays).
local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  local seen = {}
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
    seen[k] = true
  end
  for k, _ in pairs(b) do
    if not seen[k] then return false end
  end
  return true
end

local function show(v)
  if type(v) ~= "table" then return tostring(v) end
  local parts = {}
  for k, x in pairs(v) do
    parts[#parts+1] = tostring(k) .. "=" .. show(x)
  end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function M.assert_deep_equal(actual, expected, msg)
  if not deep_equal(actual, expected) then
    error((msg or "values differ") ..
      "\n  expected: " .. show(expected) ..
      "\n  actual:   " .. show(actual), 2)
  end
end

-- Fake UCI cursor matching the subset of the API we use:
-- cursor:get(config, section, option) -> string|nil
-- cursor:get_list(config, section, option) -> array (possibly empty)
function M.fake_cursor(data)
  local cur = {}
  function cur:get(config, section, option)
    local s = (data[config] or {})[section] or {}
    local v = s[option]
    if type(v) == "table" then return nil end
    return v
  end
  function cur:get_list(config, section, option)
    local s = (data[config] or {})[section] or {}
    local v = s[option]
    if type(v) == "table" then return v end
    if v == nil then return {} end
    return { v }
  end
  return cur
end

local _passed, _failed = 0, 0
function M.test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    _passed = _passed + 1
    io.write("  ok    " .. name .. "\n")
  else
    _failed = _failed + 1
    io.write("  FAIL  " .. name .. "\n")
    io.write("        " .. tostring(err) .. "\n")
  end
end

function M.summary()
  io.write(string.format("# %d passed, %d failed\n", _passed, _failed))
  os.exit(_failed == 0 and 0 or 1)
end

return M
```

- [ ] **Step 2: Write the test runner script**

```bash
#!/bin/sh
# tests/run.sh
set -e
cd "$(dirname "$0")/.."

echo "==> Lua tests"
for t in tests/test_*.lua; do
  [ -e "$t" ] || continue
  echo "-- $t"
  lua5.1 "$t"
done

echo "==> Shell tests"
for t in tests/test_*.sh; do
  [ -e "$t" ] || continue
  echo "-- $t"
  sh "$t"
done

echo "All tests passed."
```

Then `chmod +x tests/run.sh`.

- [ ] **Step 3: Sanity-check the helper with a throwaway test**

Create `tests/test_helpers_smoke.lua`:

```lua
local h = dofile("tests/helpers.lua")
h.test("deep_equal: nested tables", function()
  h.assert_deep_equal({a = {1, 2, 3}}, {a = {1, 2, 3}})
end)
h.test("fake_cursor: get_list returns array", function()
  local cur = h.fake_cursor({ ["sing-box"] = { fakeip = { inet4_range = {"198.18.0.0/15"} } } })
  h.assert_deep_equal(cur:get_list("sing-box", "fakeip", "inet4_range"), {"198.18.0.0/15"})
end)
h.test("fake_cursor: get returns nil for missing", function()
  local cur = h.fake_cursor({})
  h.assert_deep_equal(cur:get("sing-box", "x", "y"), nil)
end)
h.summary()
```

Run: `lua5.1 tests/test_helpers_smoke.lua`.
Expected: `# 3 passed, 0 failed`.

Then **delete** `tests/test_helpers_smoke.lua` — it was a sanity check, not a permanent test.

- [ ] **Step 4: Write the Makefile**

```makefile
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-sing-box
PKG_VERSION:=0.1.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0-or-later
PKG_MAINTAINER:=Jyn

LUCI_TITLE:=LuCI support for sing-box
LUCI_DEPENDS:=+luci-base +nftables +sing-box
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./root/etc/config/sing-box $(1)/etc/config/sing-box

	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./root/etc/uci-defaults/99-luci-app-sing-box \
	  $(1)/etc/uci-defaults/99-luci-app-sing-box

	$(INSTALL_DIR) $(1)/etc/sing-box
	$(INSTALL_BIN) ./root/etc/sing-box/nftables.sh $(1)/etc/sing-box/nftables.sh

	$(INSTALL_DIR) $(1)/usr/libexec/rpcd
	$(INSTALL_BIN) ./root/usr/libexec/rpcd/sing-box $(1)/usr/libexec/rpcd/sing-box

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./root/usr/share/luci/menu.d/luci-app-sing-box.json \
	  $(1)/usr/share/luci/menu.d/luci-app-sing-box.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./root/usr/share/rpcd/acl.d/luci-app-sing-box.json \
	  $(1)/usr/share/rpcd/acl.d/luci-app-sing-box.json

	$(INSTALL_DIR) $(1)/usr/share/sing-box
	$(INSTALL_DATA) ./root/usr/share/sing-box/generate.lua \
	  $(1)/usr/share/sing-box/generate.lua
	$(INSTALL_DATA) ./root/usr/share/sing-box/sing_box_config.lua \
	  $(1)/usr/share/sing-box/sing_box_config.lua

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view/sing-box
	$(INSTALL_DATA) ./htdocs/luci-static/resources/view/sing-box/main.js \
	  $(1)/www/luci-static/resources/view/sing-box/main.js
endef

# call BuildPackage - OpenWrt buildroot signature
$(eval $(call BuildPackage,$(PKG_NAME)))
```

(The Makefile cannot be executed locally — it's run inside an OpenWrt buildroot. We verify only that it parses as a Makefile.)

- [ ] **Step 5: Verify Makefile syntax**

Run: `make -n -f Makefile 2>&1 | head -5` from the repo root.
Expected: `make` complains about missing `$(TOPDIR)/rules.mk` but does **not** report a syntax error. A line like `Makefile:1: *** missing separator` is a failure; a line like `Makefile:1: <stdin>: No such file or directory` plus `*** No rule to make target` is fine — that just means the file can't be evaluated outside an OpenWrt tree.

- [ ] **Step 6: Write the LuCI menu definition**

`root/usr/share/luci/menu.d/luci-app-sing-box.json`:

```json
{
    "admin/services/sing-box": {
        "title": "Sing-Box",
        "order": 60,
        "action": {
            "type": "view",
            "path": "sing-box/main"
        },
        "depends": {
            "acl": [ "luci-app-sing-box" ],
            "uci": { "sing-box": true }
        }
    }
}
```

- [ ] **Step 7: Validate the JSON**

Run: `jq -e . root/usr/share/luci/menu.d/luci-app-sing-box.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 8: Commit**

```bash
git add Makefile root/usr/share/luci/menu.d/luci-app-sing-box.json tests/helpers.lua tests/run.sh
git commit -m "feat: add package skeleton, LuCI menu entry, and test harness"
```

---

## Task 2: UCI defaults — config file and first-run init script

**Files:**
- Create: `root/etc/config/sing-box`
- Create: `root/etc/uci-defaults/99-luci-app-sing-box`

- [ ] **Step 1: Write the default UCI config**

`root/etc/config/sing-box`:

```
config fakeip 'fakeip'
	option enabled '0'
	list inet4_range '198.18.0.0/15'
	list inet6_range 'fc00::/18'

config tproxy 'tproxy'
	option enabled '0'
	option interface 'br-lan'
	option port '7893'

config nftables 'nftables'
	option enabled '0'
```

(Tabs, not spaces — matches OpenWrt convention.)

- [ ] **Step 2: Write the uci-defaults init script**

`root/etc/uci-defaults/99-luci-app-sing-box`:

```sh
#!/bin/sh
# Run by OpenWrt on first boot after package install. Removes itself on success.

# Force LuCI's RPC ACL cache to reload so the menu entry appears immediately.
rm -f /tmp/luci-indexcache /tmp/luci-modulecache/* 2>/dev/null

# Reload rpcd so the new ACL JSON is picked up.
/etc/init.d/rpcd reload >/dev/null 2>&1

exit 0
```

Then `chmod +x root/etc/uci-defaults/99-luci-app-sing-box`.

- [ ] **Step 3: Validate the UCI config syntactically**

There is no offline UCI parser in apt, but UCI's grammar is simple enough that we can sanity-check with grep:

```bash
# Each line must be blank, a comment, or start with: config|option|list <name> <value?>
awk 'NF==0 || /^[[:space:]]*#/ {next}
     !/^[[:space:]]*(config|option|list)[[:space:]]+/ {print "BAD: "$0; exit 1}' \
  root/etc/config/sing-box && echo OK
```

Expected: `OK`.

- [ ] **Step 4: Validate the init script with shellcheck**

Run: `shellcheck -s sh root/etc/uci-defaults/99-luci-app-sing-box && echo OK`
Expected: `OK`.

- [ ] **Step 5: Commit**

```bash
git add root/etc/config/sing-box root/etc/uci-defaults/99-luci-app-sing-box
git commit -m "feat: ship default UCI config and first-run init script"
```

---

## Task 3: rpcd ACL

**Files:**
- Create: `root/usr/share/rpcd/acl.d/luci-app-sing-box.json`

- [ ] **Step 1: Write the ACL JSON**

```json
{
    "luci-app-sing-box": {
        "description": "Grant access to the sing-box LuCI page",
        "read": {
            "uci": [ "sing-box" ],
            "ubus": {
                "network.interface": [ "dump" ]
            }
        },
        "write": {
            "uci": [ "sing-box" ],
            "ubus": {
                "sing-box": [ "generate", "nftables" ]
            }
        }
    }
}
```

`network.interface.dump` is read because the TProxy section's interface dropdown is populated from it.

- [ ] **Step 2: Validate the JSON**

Run: `jq -e . root/usr/share/rpcd/acl.d/luci-app-sing-box.json >/dev/null && echo OK`
Expected: `OK`.

- [ ] **Step 3: Verify ACL name matches LuCI menu and rpcd handler will provide methods**

```bash
grep -l '"luci-app-sing-box"' \
  root/usr/share/luci/menu.d/luci-app-sing-box.json \
  root/usr/share/rpcd/acl.d/luci-app-sing-box.json
```

Expected: both file paths printed. If only one is printed the names disagree; fix before committing.

- [ ] **Step 4: Commit**

```bash
git add root/usr/share/rpcd/acl.d/luci-app-sing-box.json
git commit -m "feat: declare rpcd ACL for sing-box LuCI app"
```

---

## Task 4: Pure Lua config builder (`sing_box_config.lua`) — TDD

This is the only piece of business logic in the package. Build it test-first.

**Files:**
- Test: `tests/test_sing_box_config.lua`
- Create: `root/usr/share/sing-box/sing_box_config.lua`

- [ ] **Step 1: Write the failing tests for `build_config`**

```lua
-- tests/test_sing_box_config.lua
package.path = "root/usr/share/sing-box/?.lua;tests/?.lua;" .. package.path
local h = require("helpers")
local sbc = require("sing_box_config")

h.test("build_config: empty when nothing enabled", function()
  local out = sbc.build_config({
    fakeip = { enabled = false, inet4_range = {}, inet6_range = {} },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {})
end)

h.test("build_config: emits dns.fakeip when fakeip enabled", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {
    dns = {
      fakeip = {
        enabled = true,
        inet4_range = { "198.18.0.0/15" },
        inet6_range = { "fc00::/18" },
      },
    },
  })
end)

h.test("build_config: emits tproxy inbound when tproxy enabled", function()
  local out = sbc.build_config({
    fakeip = { enabled = false, inet4_range = {}, inet6_range = {} },
    tproxy = { enabled = true, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out, {
    inbounds = { {
      type = "tproxy",
      listen = "::",
      listen_port = 7893,
    } },
  })
end)

h.test("build_config: both sections enabled", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = true, interface = "br-lan", port = 1234 },
  })
  h.assert_deep_equal(out.dns.fakeip.enabled, true)
  h.assert_deep_equal(out.inbounds[1].listen_port, 1234)
end)

h.test("build_config: multiple ranges preserved in order", function()
  local out = sbc.build_config({
    fakeip = {
      enabled = true,
      inet4_range = { "198.18.0.0/15", "10.0.0.0/8" },
      inet6_range = {},
    },
    tproxy = { enabled = false, interface = "br-lan", port = 7893 },
  })
  h.assert_deep_equal(out.dns.fakeip.inet4_range, { "198.18.0.0/15", "10.0.0.0/8" })
  h.assert_deep_equal(out.dns.fakeip.inet6_range, {})
end)

-- read_uci tests use the fake cursor from helpers.

h.test("read_uci: parses '1' as enabled and string port as number", function()
  local cur = h.fake_cursor({
    ["sing-box"] = {
      fakeip = {
        enabled = "1",
        inet4_range = { "198.18.0.0/15" },
        inet6_range = { "fc00::/18" },
      },
      tproxy = {
        enabled = "0",
        interface = "br-lan",
        port = "7893",
      },
    },
  })
  local s = sbc.read_uci(cur)
  h.assert_deep_equal(s.fakeip.enabled, true)
  h.assert_deep_equal(s.tproxy.enabled, false)
  h.assert_deep_equal(s.tproxy.port, 7893)
  h.assert_deep_equal(s.fakeip.inet4_range, { "198.18.0.0/15" })
end)

h.test("read_uci: missing values fall back to safe defaults", function()
  local cur = h.fake_cursor({ ["sing-box"] = {} })
  local s = sbc.read_uci(cur)
  h.assert_deep_equal(s.fakeip.enabled, false)
  h.assert_deep_equal(s.fakeip.inet4_range, {})
  h.assert_deep_equal(s.tproxy.port, 7893)
  h.assert_deep_equal(s.tproxy.interface, "br-lan")
end)

h.summary()
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `lua5.1 tests/test_sing_box_config.lua`
Expected: errors out with `module 'sing_box_config' not found`. The fail mode is "module missing", which is what we want before we create it.

- [ ] **Step 3: Write the module**

`root/usr/share/sing-box/sing_box_config.lua`:

```lua
local M = {}

local function as_bool(v)
  return v == "1" or v == 1 or v == true
end

function M.read_uci(cursor)
  local cur = cursor or require("uci").cursor()
  local function get(section, option)
    return cur:get("sing-box", section, option)
  end
  local function list(section, option)
    return cur:get_list("sing-box", section, option) or {}
  end
  return {
    fakeip = {
      enabled = as_bool(get("fakeip", "enabled")),
      inet4_range = list("fakeip", "inet4_range"),
      inet6_range = list("fakeip", "inet6_range"),
    },
    tproxy = {
      enabled = as_bool(get("tproxy", "enabled")),
      interface = get("tproxy", "interface") or "br-lan",
      port = tonumber(get("tproxy", "port")) or 7893,
    },
    nftables = {
      enabled = as_bool(get("nftables", "enabled")),
    },
  }
end

function M.build_config(state)
  local out = {}
  if state.fakeip.enabled then
    out.dns = {
      fakeip = {
        enabled = true,
        inet4_range = state.fakeip.inet4_range,
        inet6_range = state.fakeip.inet6_range,
      },
    }
  end
  if state.tproxy.enabled then
    out.inbounds = { {
      type = "tproxy",
      listen = "::",
      listen_port = state.tproxy.port,
    } }
  end
  return out
end

return M
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `lua5.1 tests/test_sing_box_config.lua`
Expected: `# 7 passed, 0 failed` and exit code 0.

- [ ] **Step 5: Commit**

```bash
git add root/usr/share/sing-box/sing_box_config.lua tests/test_sing_box_config.lua
git commit -m "feat: add sing_box_config Lua module that turns UCI into a config table"
```

---

## Task 5: `generate.lua` entrypoint and end-to-end smoke test

**Files:**
- Create: `root/usr/share/sing-box/generate.lua`
- Test: `tests/test_generate_smoke.lua`

- [ ] **Step 1: Write the entrypoint**

`root/usr/share/sing-box/generate.lua`:

```lua
#!/usr/bin/env lua

-- Make the helper module reachable on OpenWrt where /usr/share/sing-box is
-- not on package.path.
package.path = "/usr/share/sing-box/?.lua;" .. package.path

local sbc = require("sing_box_config")
local jsonc = require("luci.jsonc")

local state = sbc.read_uci()
local config = sbc.build_config(state)

local out = assert(io.open("/tmp/sing-box.json", "w"))
out:write(jsonc.stringify(config, true))
out:write("\n")
out:close()

io.write("OK\n")
```

- [ ] **Step 2: Write the smoke test**

The test stubs `uci` and `luci.jsonc` so we can run `generate.lua` in dev. It writes to a temp file (overrides the `/tmp/sing-box.json` path via a wrapped `io.open`), then asserts on the result with `cjson`.

```lua
-- tests/test_generate_smoke.lua
local h = dofile("tests/helpers.lua")

-- Stub the OpenWrt-only modules.
local fake_data = {
  ["sing-box"] = {
    fakeip = {
      enabled = "1",
      inet4_range = { "198.18.0.0/15" },
      inet6_range = { "fc00::/18" },
    },
    tproxy = { enabled = "1", interface = "br-lan", port = "7893" },
    nftables = { enabled = "0" },
  },
}

package.preload["uci"] = function()
  return { cursor = function() return h.fake_cursor(fake_data) end }
end

local cjson = require("cjson")
package.preload["luci.jsonc"] = function()
  return { stringify = function(v) return cjson.encode(v) end }
end

-- Redirect /tmp/sing-box.json to a unique tmp file.
local tmp = os.tmpname()
local real_open = io.open
io.open = function(path, mode)
  if path == "/tmp/sing-box.json" then return real_open(tmp, mode) end
  return real_open(path, mode)
end

-- Make the entrypoint find the helper module locally.
package.path = "root/usr/share/sing-box/?.lua;" .. package.path

dofile("root/usr/share/sing-box/generate.lua")

local f = assert(io.open(tmp, "r"))
local body = f:read("*a")
f:close()
os.remove(tmp)

local decoded = cjson.decode(body)
h.test("generate.lua: dns.fakeip emitted", function()
  h.assert_deep_equal(decoded.dns.fakeip.enabled, true)
  h.assert_deep_equal(decoded.dns.fakeip.inet4_range, { "198.18.0.0/15" })
end)
h.test("generate.lua: tproxy inbound emitted", function()
  h.assert_deep_equal(decoded.inbounds[1].type, "tproxy")
  h.assert_deep_equal(decoded.inbounds[1].listen_port, 7893)
end)
h.summary()
```

- [ ] **Step 3: Run the smoke test**

Run: `lua5.1 tests/test_generate_smoke.lua`
Expected: `# 2 passed, 0 failed`.

If `cjson` reports an error about distinguishing array vs object for `inet4_range`, that is a real issue worth fixing in this task — wrap the list with `setmetatable(state.fakeip.inet4_range, cjson.array_mt)` ... but with the current `cjson` (2.1) and a list with at least one element, it serializes correctly as a JSON array. The unit tests in Task 4 cover the empty-list case at the table level; the JSON-array-vs-object empty-list edge case is out of scope for the first iteration (documented in spec "Ограничения первой итерации").

- [ ] **Step 4: Commit**

```bash
git add root/usr/share/sing-box/generate.lua tests/test_generate_smoke.lua
git commit -m "feat: add generate.lua entrypoint that writes /tmp/sing-box.json"
```

---

## Task 6: `nftables.sh` with rule emitter and validation tests

**Files:**
- Create: `root/etc/sing-box/nftables.sh`
- Test: `tests/test_nftables_emit.sh`

- [ ] **Step 1: Write the failing test**

```sh
#!/bin/sh
# tests/test_nftables_emit.sh
set -e

SCRIPT=root/etc/sing-box/nftables.sh

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: $SCRIPT not present or not executable"
  exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$SCRIPT"

echo "-- emit prints rules referencing port and ranges"
out=$("$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18")
echo "$out" | grep -q "table inet sing_box"  || { echo "FAIL: missing table"; exit 1; }
echo "$out" | grep -q "127.0.0.1:7893"        || { echo "FAIL: missing v4 tproxy target"; exit 1; }
echo "$out" | grep -q "\[::1\]:7893"          || { echo "FAIL: missing v6 tproxy target"; exit 1; }
echo "$out" | grep -q "198.18.0.0/15"         || { echo "FAIL: missing v4 range"; exit 1; }
echo "$out" | grep -q "fc00::/18"             || { echo "FAIL: missing v6 range"; exit 1; }

echo "-- nft -c accepts the emitted rules"
tmp=$(mktemp)
"$SCRIPT" emit 7893 "198.18.0.0/15" "fc00::/18" > "$tmp"
if ! nft -c -f "$tmp" 2>nft.err; then
  # Some kernels lack tproxy; treat that specifically as a skip rather than a failure.
  if grep -qi "tproxy" nft.err; then
    echo "SKIP: kernel lacks tproxy support"
  else
    echo "FAIL: nft rejected emitted rules:"
    cat nft.err
    exit 1
  fi
fi
rm -f "$tmp" nft.err

echo "-- emit accepts comma-separated multi-element sets"
out=$("$SCRIPT" emit 7893 "198.18.0.0/15,10.0.0.0/8" "fc00::/18")
echo "$out" | grep -q "10.0.0.0/8" || { echo "FAIL: second v4 element missing"; exit 1; }

echo "OK"
```

Then `chmod +x tests/test_nftables_emit.sh`.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `sh tests/test_nftables_emit.sh`
Expected: `FAIL: root/etc/sing-box/nftables.sh not present or not executable`.

- [ ] **Step 3: Write the script**

`root/etc/sing-box/nftables.sh`:

```sh
#!/bin/sh
# Apply or remove the sing-box nftables redirect rules.
# Subcommands:
#   apply           Read UCI, generate rules, apply via nft.
#   remove          Delete the sing_box table.
#   emit P V4 V6    Print rules to stdout (used by tests). V4/V6 are
#                   already comma-separated set bodies.

set -eu

emit() {
	port="$1"
	v4="$2"
	v6="$3"
	cat <<EOF
table inet sing_box {
	chain prerouting {
		type filter hook prerouting priority mangle; policy accept;

		ip daddr { ${v4} } meta l4proto { tcp, udp } tproxy ip to 127.0.0.1:${port} meta mark set 1
		ip6 daddr { ${v6} } meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port} meta mark set 1
	}
}
EOF
}

apply() {
	# UCI list values come back space-separated; nft set syntax wants commas.
	port=$(uci -q get sing-box.tproxy.port)
	port=${port:-7893}
	v4=$(uci -q get sing-box.fakeip.inet4_range | tr ' ' ',')
	v6=$(uci -q get sing-box.fakeip.inet6_range | tr ' ' ',')

	if [ -z "$v4" ] && [ -z "$v6" ]; then
		echo "nftables.sh: no fakeip ranges configured; nothing to apply" >&2
		return 1
	fi

	# Replace any prior incarnation atomically: delete-if-exists then re-add.
	nft delete table inet sing_box 2>/dev/null || true
	emit "$port" "$v4" "$v6" | nft -f -
}

remove() {
	nft delete table inet sing_box 2>/dev/null || true
}

case "${1:-}" in
	apply)  apply ;;
	remove) remove ;;
	emit)
		[ "$#" -eq 4 ] || { echo "Usage: $0 emit PORT V4SET V6SET" >&2; exit 2; }
		emit "$2" "$3" "$4"
		;;
	*)
		echo "Usage: $0 {apply|remove|emit PORT V4SET V6SET}" >&2
		exit 2
		;;
esac
```

Then `chmod +x root/etc/sing-box/nftables.sh`.

- [ ] **Step 4: Re-run the test and verify it passes**

Run: `sh tests/test_nftables_emit.sh`
Expected: ends with `OK`. If the local kernel lacks tproxy support, the test prints `SKIP: kernel lacks tproxy support` for the `nft -c` step and continues — that's acceptable, syntax was still parsed up to the keyword. (`nft -c -f` errors before the tproxy keyword would be a real failure.)

- [ ] **Step 5: Commit**

```bash
git add root/etc/sing-box/nftables.sh tests/test_nftables_emit.sh
git commit -m "feat: add nftables.sh with apply/remove/emit subcommands"
```

---

## Task 7: rpcd handler script

**Files:**
- Create: `root/usr/libexec/rpcd/sing-box`
- Test: `tests/test_rpcd_handler.sh`

The handler is invoked by ubus. We can't run it through ubus locally, but we can verify its `list` output is valid JSON and its dispatch logic works under a stubbed environment.

- [ ] **Step 1: Write the failing test**

```sh
#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=root/usr/libexec/rpcd/sing-box

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

echo "-- shellcheck"
shellcheck -s sh "$H"

echo "-- list emits valid JSON with both methods"
out=$("$H" list)
echo "$out" | jq -e '.generate' >/dev/null || { echo "FAIL: missing generate"; exit 1; }
echo "$out" | jq -e '.nftables.action' >/dev/null || { echo "FAIL: missing nftables.action"; exit 1; }

echo "-- call generate dispatches to generate.lua"
# Stub the path so we can assert it was invoked. Use a wrapper script.
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
cat >"$tmpdir/lua" <<'EOF'
#!/bin/sh
echo "called lua with: $*" >&2
echo "OK"
EOF
chmod +x "$tmpdir/lua"
PATH="$tmpdir:$PATH" out=$(echo '{}' | "$H" call generate 2>"$tmpdir/err")
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: generate did not return ok"; cat "$tmpdir/err"; exit 1; }
grep -q "generate.lua" "$tmpdir/err" || { echo "FAIL: generate.lua not invoked"; cat "$tmpdir/err"; exit 1; }

echo "-- call nftables apply dispatches to nftables.sh"
cat >"$tmpdir/nftables.sh" <<'EOF'
#!/bin/sh
echo "called nftables with: $*" >&2
EOF
chmod +x "$tmpdir/nftables.sh"
out=$(echo '{"action":"apply"}' | NFTABLES_SH="$tmpdir/nftables.sh" "$H" call nftables 2>"$tmpdir/err2")
echo "$out" | jq -e '.status == "ok"' >/dev/null || { echo "FAIL: nftables apply did not return ok"; cat "$tmpdir/err2"; exit 1; }
grep -q "called nftables with: apply" "$tmpdir/err2" || { echo "FAIL: nftables.sh not invoked with apply"; cat "$tmpdir/err2"; exit 1; }

echo "-- call nftables with bad action returns error"
out=$(echo '{"action":"haxx"}' | NFTABLES_SH="$tmpdir/nftables.sh" "$H" call nftables)
echo "$out" | jq -e '.status == "error"' >/dev/null || { echo "FAIL: bad action should return error"; exit 1; }

echo "OK"
```

Then `chmod +x tests/test_rpcd_handler.sh`.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `sh tests/test_rpcd_handler.sh`
Expected: `FAIL: root/usr/libexec/rpcd/sing-box not present or not executable`.

- [ ] **Step 3: Write the handler**

`root/usr/libexec/rpcd/sing-box`:

```sh
#!/bin/sh
# rpcd handler for sing-box. Methods:
#   generate        run /usr/share/sing-box/generate.lua
#   nftables {action}  run /etc/sing-box/nftables.sh apply|remove
#
# On OpenWrt, libubox's jshn.sh is available. For dev tests we shell out to
# `jq` if jshn.sh is missing.
#
# NFTABLES_SH and GENERATE_LUA env vars override the script paths (used by tests).

NFTABLES_SH=${NFTABLES_SH:-/etc/sing-box/nftables.sh}
GENERATE_LUA=${GENERATE_LUA:-/usr/share/sing-box/generate.lua}

emit_list() {
	cat <<'EOF'
{
	"generate": {},
	"nftables": { "action": "string" }
}
EOF
}

emit_ok() {
	printf '{"status":"ok"}\n'
}

emit_err() {
	# $1 is the message
	# Use printf with %s and a manual escape for embedded quotes; messages here
	# are short and controlled, so a basic escape is sufficient.
	msg=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
	printf '{"status":"error","message":"%s"}\n' "$msg"
}

read_action() {
	# stdin is the JSON args object. Pull `action` out via jq if available,
	# else fall back to a hand-rolled grep. We deliberately keep this simple;
	# the LuCI frontend is the only caller.
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
		# Drain stdin even though we ignore args.
		cat >/dev/null
		if out=$(lua "$GENERATE_LUA" 2>&1); then
			emit_ok
		else
			emit_err "$out"
		fi
		;;
	nftables)
		action=$(read_action)
		case "$action" in
		apply|remove)
			if out=$("$NFTABLES_SH" "$action" 2>&1); then
				emit_ok
			else
				emit_err "$out"
			fi
			;;
		*)
			emit_err "invalid action: ${action:-<missing>}"
			;;
		esac
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

Then `chmod +x root/usr/libexec/rpcd/sing-box`.

- [ ] **Step 4: Re-run the test and verify it passes**

Run: `sh tests/test_rpcd_handler.sh`
Expected: ends with `OK`.

- [ ] **Step 5: Verify the full test suite still passes**

Run: `sh tests/run.sh`
Expected: all Lua and shell tests print "passed" / "OK"; final line `All tests passed.`

- [ ] **Step 6: Commit**

```bash
git add root/usr/libexec/rpcd/sing-box tests/test_rpcd_handler.sh
git commit -m "feat: add rpcd handler exposing sing-box.generate and sing-box.nftables"
```

---

## Task 8: LuCI view (`main.js`) — three sections, save hook, generate button

**Files:**
- Create: `htdocs/luci-static/resources/view/sing-box/main.js`
- Test: `tests/test_main_js_syntax.sh`

The view is one page. The form is a `form.Map` over the `sing-box` UCI config with three named sections. After save, if the `nftables.enabled` value flipped, the page calls `sing-box.nftables` over rpcd. A separate Generate button outside the form calls `sing-box.generate`.

- [ ] **Step 1: Write the syntax-check test**

```sh
#!/bin/sh
# tests/test_main_js_syntax.sh
set -e

JS=htdocs/luci-static/resources/view/sing-box/main.js

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
grep -q "'require view'"   "$JS" || { echo "FAIL: missing 'require view'"; exit 1; }
grep -q "'require form'"   "$JS" || { echo "FAIL: missing 'require form'"; exit 1; }
grep -q "'require uci'"    "$JS" || { echo "FAIL: missing 'require uci'"; exit 1; }
grep -q "'require rpc'"    "$JS" || { echo "FAIL: missing 'require rpc'"; exit 1; }
grep -q "'require ui'"     "$JS" || { echo "FAIL: missing 'require ui'"; exit 1; }
grep -q "'require network'" "$JS" || { echo "FAIL: missing 'require network'"; exit 1; }

echo "-- references all three UCI sections"
grep -q "fakeip"   "$JS" || { echo "FAIL: no fakeip section"; exit 1; }
grep -q "tproxy"   "$JS" || { echo "FAIL: no tproxy section"; exit 1; }
grep -q "nftables" "$JS" || { echo "FAIL: no nftables section"; exit 1; }

echo "-- wires the rpcd methods"
grep -q "sing-box.*generate"  "$JS" || { echo "FAIL: no generate rpc binding"; exit 1; }
grep -q "sing-box.*nftables"  "$JS" || { echo "FAIL: no nftables rpc binding"; exit 1; }

echo "OK"
```

Then `chmod +x tests/test_main_js_syntax.sh`.

- [ ] **Step 2: Run the test, confirm it fails**

Run: `sh tests/test_main_js_syntax.sh`
Expected: `FAIL: htdocs/luci-static/resources/view/sing-box/main.js not present`.

- [ ] **Step 3: Write the view**

`htdocs/luci-static/resources/view/sing-box/main.js`:

```js
'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require network';

var callGenerate = rpc.declare({
	object: 'sing-box',
	method: 'generate',
	expect: { status: 'error' }
});

var callNftables = rpc.declare({
	object: 'sing-box',
	method: 'nftables',
	params: [ 'action' ],
	expect: { status: 'error' }
});

function syncNftables(prevEnabled, nextEnabled) {
	if (prevEnabled === nextEnabled) return Promise.resolve();
	var action = nextEnabled ? 'apply' : 'remove';
	return callNftables(action).then(function (status) {
		// expect:{status:'error'} returns the value of the `status` key, falling
		// back to the literal 'error' if the key is missing. So 'ok' is success
		// and anything else is failure.
		if (status && status !== 'ok') {
			ui.addNotification(null,
				E('p', _('nftables %s failed: %s').format(action, String(status))),
				'danger');
		}
	});
}

return view.extend({
	load: function () {
		return Promise.all([
			network.getDevices(),
			uci.load('sing-box')
		]);
	},

	render: function (data) {
		var devices = data[0];
		var prevNftEnabled = uci.get('sing-box', 'nftables', 'enabled') === '1';

		var m, s, o;

		m = new form.Map('sing-box', _('Sing-Box'),
			_('Configure FakeIP, TProxy inbound, and nftables redirect rules. ' +
			  'Use the Generate Config button to write /tmp/sing-box.json.'));

		// --- FakeIP ---
		s = m.section(form.NamedSection, 'fakeip', 'fakeip', _('FakeIP'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'inet4_range', _('IPv4 ranges'));
		o.datatype = 'cidr4';
		o.placeholder = '198.18.0.0/15';

		o = s.option(form.DynamicList, 'inet6_range', _('IPv6 ranges'));
		o.datatype = 'cidr6';
		o.placeholder = 'fc00::/18';

		// --- TProxy Inbound ---
		s = m.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
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

		// --- nftables ---
		s = m.section(form.NamedSection, 'nftables', 'nftables', _('nftables'),
			_('Apply the redirect rules required to send FakeIP traffic to ' +
			  'the TProxy inbound. Toggling this flag invokes apply or remove ' +
			  'on save.'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		// Hook the post-save step: act on the new nftables.enabled value.
		m.onSaveAfter = function () {
			var nextEnabled = uci.get('sing-box', 'nftables', 'enabled') === '1';
			return syncNftables(prevNftEnabled, nextEnabled).then(function () {
				prevNftEnabled = nextEnabled;
			});
		};

		// --- Generate Config button (outside the form) ---
		var generateBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				return callGenerate().then(function (status) {
					if (!status || status === 'ok') {
						ui.addNotification(null,
							E('p', _('sing-box config written to /tmp/sing-box.json')),
							'info');
					} else {
						ui.addNotification(null,
							E('p', _('Generate failed: %s').format(String(status))),
							'danger');
					}
				});
			})
		}, _('Generate Config'));

		return m.render().then(function (mapNode) {
			return E([], [
				mapNode,
				E('div', { 'class': 'cbi-page-actions', 'style': 'margin-top:1em' },
					generateBtn)
			]);
		});
	},

	handleSaveApply: null,
	handleApply: null,
	handleReset: null
});
```

Notes for the engineer:

- `m.onSaveAfter` is a documented LuCI hook fired after the form has flushed changes back to UCI. We diff the previous/next `enabled` flag and dispatch `apply` or `remove` accordingly. We do **not** dispatch when the flag did not change — that avoids re-applying rules every time the user touches an unrelated field.
- `expect: { status: 'error' }` is a small idiom: `rpc.declare` returns the value at the given key from the response; the second argument is the fallback when the key is missing. So a rpcd return of `{"status":"ok"}` resolves to `"ok"`, and a malformed response (no `status` key) resolves to `"error"`.
- The "Save" / "Save & Apply" / "Reset" defaults are explicitly nulled because LuCI normally renders an "Apply" footer that triggers UCI commit + service restart; here we don't restart anything, so the default footer just confuses users.
- `ui.createHandlerFn` wraps the click handler with a spinner and disables the button while the call is in flight.

- [ ] **Step 4: Re-run the syntax test and verify it passes**

Run: `sh tests/test_main_js_syntax.sh`
Expected: ends with `OK`.

- [ ] **Step 5: Run the full test suite**

Run: `sh tests/run.sh`
Expected: every test passes; final line `All tests passed.`

- [ ] **Step 6: Final consistency sweep**

```bash
# All references to the ACL/menu name should agree.
grep -rn "luci-app-sing-box" root/ htdocs/ tests/ Makefile

# All references to the ubus service name should agree.
grep -rn "sing-box" root/usr/share/rpcd/ root/usr/libexec/rpcd/ htdocs/

# No leftover placeholder strings in shipped code.
grep -rn -E '\b(TBD|TODO|FIXME|XXX)\b' root/ htdocs/ Makefile && echo "FAIL: placeholders" && exit 1 || echo "OK: no placeholders"
```

Expected: ACL names match across menu.d, acl.d, and the Makefile. ubus service `sing-box` appears in acl.d, the rpcd handler, and main.js's `rpc.declare` calls. No placeholder strings.

- [ ] **Step 7: Commit**

```bash
git add htdocs/luci-static/resources/view/sing-box/main.js tests/test_main_js_syntax.sh
git commit -m "feat: add LuCI view with FakeIP, TProxy, nftables, and Generate button"
```

---

## Manual verification on a real OpenWrt 25 device

The local test suite covers logic and syntax. Confirm the package actually works by running through the following on a target device after `make package/luci-app-sing-box/install` from an OpenWrt buildroot:

1. `opkg install luci-app-sing-box_*.ipk` — installs cleanly.
2. Open LuCI → **Services → Sing-Box** — page renders with three sections.
3. Toggle **FakeIP → Enable**, save — `uci show sing-box` reflects the change.
4. Click **Generate Config** — `/tmp/sing-box.json` exists and contains the expected `dns.fakeip` block.
5. Toggle **nftables → Enable**, save — `nft list table inet sing_box` shows the rules.
6. Toggle **nftables → Enable** off, save — `nft list table inet sing_box` returns "No such file or directory".
7. `ubus call sing-box generate` from the device shell returns `{"status":"ok"}`.

Document any deviations as bugs in a follow-up task; do not patch them in this iteration.

---

## Out of scope for this iteration

These are explicitly deferred (per spec, "Ограничения первой итерации"):

- CIDR validation in the UI beyond LuCI's built-in `cidr4`/`cidr6` datatypes.
- Auto-start/stop of the `sing-box` service on save.
- Config application — `/tmp/sing-box.json` is generated but not handed to a running sing-box instance.
- JSON empty-array vs empty-object edge case when fakeip is enabled with zero ranges.

If a future iteration needs these, write a separate spec and plan.
