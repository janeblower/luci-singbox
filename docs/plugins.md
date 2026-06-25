# Plugin API (Phase E)

An extension point that lets operator-trusted code add new protocol types,
rpcd methods, lifecycle hooks, nftables fragments, and LuCI UI tabs — all
from a separate installable `.apk` that depends only on `luci-app-singbox-ui`.

Phase E builds on the Phase D `on_generate_post` hook and adds: subdirectory
discovery, the full hook set (rpcd, lifecycle, nft), the `plugins` / `plugin_enable`
/ `plugin_install` rpcd methods, and the frontend dynamic-load contract.

---

## Threat model

Plugins are **trusted code**. Installing a plugin package requires root on the
router (via `apk`). That is the same privilege required to write any rootfs
file directly. The plugin runtime adds no new attack surface:

- Plugins are not sandboxed.
- Plugins may read UCI, call `system()`, mutate the sing-box config, add nft
  rules, or expose new rpcd methods.
- Plugins are not signed beyond the normal `apk` index signature.

What this means for operators: only install plugins from feeds whose signing
key you trust, or from packages you built yourself.

---

## Discovery

Plugins live under `lib/plugins/<name>/init.uc` where `<name>` is an
underscore-only identifier (letters, digits, underscores — no dashes).
Dashes in the name break ucode's `require()` module resolution.

`lib/plugins/discovery.uc` is the single discovery point used by every
consumer (rpcd handler, `apply-plugins.uc`, `nftables.uc`, `generate.uc`).
It calls:

```
fs.glob(<lib_root>/plugins/*/init.uc)
```

For each match it derives the module name `plugins.<name>.init` and calls
`require()` on it. Because ucode caches `require()` results, repeated calls
to `load_all()` are idempotent.

The lib root is resolved (in priority order):

1. The `explicit` argument passed to `load_all(explicit)`.
2. The `UCODE_APP_LIB_DIR` environment variable (used by the test harness).
3. The production path `/usr/share/singbox-ui/lib`.

A plugin whose `init.uc` throws at load time is logged via
`log_event("warn", "plugin.load_failed", {module, err})` and skipped. The
rest of the chain still loads.

### Manifest rule

The core `singbox-ui` package ships **only**:

```
usr/share/singbox-ui/lib/plugins/registry.uc
usr/share/singbox-ui/lib/plugins/discovery.uc
```

A plugin ships its own `lib/plugins/<name>/` subtree from its own package.
No plugin file may appear in the core install manifest.

---

## Backend contract: `register()`

`init.uc` calls `register()` on the registry module. Every field is optional
except `name`:

```ucode
let reg = require("plugins.registry");

reg.register({
    // --- identity (required) ---
    name:    "myplugin",   // underscore-only; used in logs and UCI
    version: "1",          // string; reported by the `plugins` rpcd method

    // --- descriptor self-registration (optional) ---
    // Set to true when init.uc require()s its own descriptor modules that
    // call builder.protocols.registry.try_register(). This field is purely
    // documentary — the framework does not read it.
    descriptors: true,

    // --- rpcd methods (optional) ---
    // Each function reads its arguments via parse_args() (stdin JSON) and
    // writes its result via printf("%J\n", ...).  Declare the same method
    // names in your own acl.d JSON under the `singbox-ui` ubus object.
    rpcd: {
        methods: {
            myplugin_hello: function () {
                printf("%J\n", { status: "ok" });
            },
        },
        acl_read:  ["myplugin_hello"],  // list of method names
        acl_write: [],
    },

    // --- lifecycle hooks (optional) ---
    // Called by apply-plugins.uc under the lifecycle-lock (same lock that
    // wraps init.d start/stop). Both functions receive a uci.cursor() and
    // must be idempotent. Errors are logged; never fatal.
    lifecycle: {
        apply:    function (cur) { /* reconcile resources from UCI */ },
        teardown: function (cur) { /* remove resources */ },
    },

    // --- nftables fragment (optional) ---
    // Return a complete `table <family> <name> { ... }` string.
    // It is appended verbatim to the core singbox_ui table and applied
    // atomically by `nft -f`. Return "" or null to contribute nothing.
    // The fragment is included even when no transparent inbound is active,
    // so a plugin may add masquerade or other rules independently.
    nft: {
        fragment: function (cur) { return ""; },
    },

    // --- config post-processing hook (optional) ---
    // Called once per generate.uc run, after core builders finish but before
    // the JSON is written to /tmp/singbox-ui.json. Mutate `config` in place.
    // ctx = { implicit_tags: [...], generation_ts: <number>, ... } (additive).
    // MUST NOT throw — exceptions are caught and logged; the config is
    // emitted as-is up to that point.
    on_generate_post: function (config, ctx) { /* mutate config in place */ },
});

return {};
```

### Hook semantics

| Hook | Caller | Runs inside lock? | Error policy |
|---|---|---|---|
| `on_generate_post(config, ctx)` | `generate.uc` via `invoke_on_generate_post` | No | Caught, logged, chain continues |
| `lifecycle.apply(cur)` | `apply-plugins.uc apply` | Yes (lifecycle-lock) | Caught, logged, next plugin continues |
| `lifecycle.teardown(cur)` | `apply-plugins.uc teardown` | Yes (lifecycle-lock) | Caught, logged, next plugin continues |
| `nft.fragment(cur)` | `nftables.uc` `append_plugin_fragments` | No (called before nft -f) | Caught, logged, fragment skipped |
| rpcd methods | rpcd handler dispatch | No | Handler owns its own error path |

### rpcd method wiring

The rpcd handler runs a plugin-merge IIFE at startup. It calls
`discovery.load_all()`, then `registry.get_rpcd_methods()`, and adds each
returned function to the dispatch table. If a plugin method name collides
with a core method name the core method wins and a warning is logged.

Plugin rpcd methods read their arguments the same way core handlers do:
`parse_args()` reads stdin JSON. They write results via `printf("%J\n", ...)`.
There is no wrapper object — the function is called directly by the dispatcher.

### Descriptor self-registration

A plugin that adds new outbound or inbound types calls
`builder.protocols.registry.try_register({...})` from a separate descriptor
module (e.g. `plugins.<name>.descriptor`). The descriptor module is loaded
via `require()` from `init.uc`. Using `try_register()` instead of `register()`
ensures a framework validation change never aborts plugin loading.

---

## Frontend contract

The LuCI loader (`lib/plugins.js`) calls the `plugins` rpcd method on page
load, then dynamically `L.require()`s each enabled plugin's frontend module.
The conventional module path is:

```
view.singbox-ui.plugins.<name>.tab
```

which maps to the file:

```
htdocs/luci-static/resources/view/singbox-ui/plugins/<name>/tab.js
```

A plugin's frontend module exports a plain object with any subset of these
methods (all optional):

```js
return {
    // Return array of [type_id, label] pairs for new outbound types.
    outboundTypes: function () {
        return [['myplugin_proto', _('My Protocol')]];
    },

    // Return array of [type_id, label] pairs for new inbound types.
    inboundTypes: function () { return []; },

    // Return array of tab descriptors to inject into the main view.
    tabs: function () {
        return [{ id: 'myplugin', label: _('My Plugin'), build: function () {
            return new form.Map('singbox-ui', _('My Plugin'));
        } }];
    },

    // Inject sections into an existing settings Map `m`.
    settingsSections: function (m) { /* m.section(...) */ },

    // Return a form renderer for the given outbound type (called by the
    // outbound tab when type === one of your outboundTypes()[*][0]).
    renderOutboundForm: function (type, section, ctx) { /* build form */ },

    // Return one mode descriptor for the main-view mode switcher.
    // Only the first mode per plugin is used.
    mode: function () {
        return { id: 'easy', label: _('Easy'),
                 render: function () { return E('div', {}, _('Easy mode')); } };
    },
};
```

#### Important: use `console.error`, NOT `L.error`

When catching a failed `L.require()` inside a plugin loader, use
`console.error(...)`. In the LuCI runtime `L.error()` creates **and throws**
a tagged exception, which re-rejects the promise and defeats the per-plugin
"log and skip" isolation. The core loader (`lib/plugins.js`) already does
this correctly; follow the same pattern in any plugin-side async code.

### `plugins` rpcd method

`ubus call singbox-ui plugins` returns:

```json
{
  "status": "ok",
  "plugins": [
    {
      "name": "myplugin",
      "version": "1",
      "enabled": true,
      "frontend_module": "view.singbox-ui.plugins.myplugin.tab",
      "installed": true
    }
  ]
}
```

`enabled` reflects the UCI option `singbox-ui.plugins.myplugin_enabled`.
Use `plugin_enable` (write ACL) to toggle it.

### `plugin_enable` rpcd method

```
ubus call singbox-ui plugin_enable '{"name":"myplugin","enabled":true}'
```

Writes `singbox-ui.plugins.myplugin_enabled=1` (or `0`) and commits UCI.
Name must match `^[a-z0-9_]+$`.

### `plugin_install` rpcd method

```
ubus call singbox-ui plugin_install '{"package":"luci-singbox-plugin-myplugin"}'
```

Runs `apk add <package>`. Package name must match `^[a-zA-Z0-9._+-]+$`.
This method installs a package from feeds already configured on the device.
It does **not** add a feed or trust a new key — that is the self-provisioning
pattern described below.

---

## Packaging a plugin as a separate `.apk`

A plugin lives under `plugins/<name>/` at the top level of this repository
(or in any standalone repo) and is built as a separate noarch package.
The layout mirrors the flat structure used by `plugins/awg_warp/` and
the skeleton under `docs/plugin-skeleton/`:

```
plugins/<name>/
  Makefile                       OpenWrt/LuCI package definition (LUCI_DEPENDS = +luci-app-singbox-ui only)
  lib/                           → installed at /usr/share/singbox-ui/lib/plugins/<name>/
    init.uc                      Framework discovery entry: calls register({...})
    protocols/<name>.uc          Outbound/inbound descriptor — mirrors builder/protocols/ layout
    <other>.uc                   Plugin-internal modules; required as plugins.<name>.<mod>
  htdocs/                        → installed at www/  (LuCI serving convention)
    luci-static/resources/view/singbox-ui/plugins/<name>/
      tab.js                     Frontend module loaded via L.require()
  root/                          → installed at /  (overlaid onto rootfs)
    usr/share/rpcd/acl.d/
      <pkg>.json                 rpcd ACL (read/write split; pkg name = the apk package name)
    usr/libexec/singbox-ui/
      <name>-provision.sh        Optional: self-provision script for external feeds
  po/                            Optional: .po / .pot translation files
  docs/                          Optional: README and other documentation
```

**build-apk.sh mapping** (used when building `.apk` with `scripts/build-apk.sh`):

| Source directory | Installed path |
|---|---|
| `lib/` | `/usr/share/singbox-ui/lib/plugins/<name>/` (recursive; includes `protocols/`) |
| `htdocs/` | `/www/` (the `htdocs/` subtree is overlaid onto `www/`) |
| `root/` | `/` (the `root/` subtree is overlaid onto the rootfs) |

**Require-name convention:** because `lib/` installs to
`/usr/share/singbox-ui/lib/plugins/<name>/`, ucode resolves modules as
`plugins.<name>.<mod>` (e.g. the descriptor at `lib/protocols/<name>.uc`
is required as `plugins.<name>.protocols.<name>`).

**Framework discovery:** `lib/plugins/discovery.uc` globs the system path
`/usr/share/singbox-ui/lib/plugins/*/init.uc`. The `init.uc` installed from
`lib/` lands at exactly that path, so discovery works automatically.

### Makefile

```makefile
PKG_NAME:=singbox-ui-plugin-<name>
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)

# luci-base is pulled in implicitly by luci.mk.
# singbox-ui is NOT listed here — the dependency is on the UI package
# (which already depends on singbox-ui).
# External runtime components (kernel modules, helper tools, third-party
# binaries) are NOT listed — they are self-provisioned at runtime via
# plugin rpcd methods (see Self-provisioning pattern below).
LUCI_DEPENDS:=+luci-app-singbox-ui
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

define Package/$(PKG_NAME)/description
  My plugin for luci-app-singbox-ui.
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
```

Key constraints:

- `LUCI_DEPENDS` must include `luci-app-singbox-ui` and nothing that is
  already in `singbox-ui`'s dependency tree unless your plugin strictly
  requires a version not yet on the device.
- External components (kernel modules, custom binaries, packages from
  third-party feeds) are **not** listed in `LUCI_DEPENDS`. Self-provision
  them at runtime via a plugin rpcd method (see below).
- Use `LUCI_PKGARCH:=all` (noarch). Only add a per-arch sub-package if
  your plugin ships a compiled binary (e.g. a Rust helper).

### ACL file

Create `root/usr/share/rpcd/acl.d/<pkg>.json` where `<pkg>` matches the
apk package name. Follow the same read/write split as the core ACL:

```json
{
  "<pkg>": {
    "description": "Grant LuCI access to myplugin rpcd methods",
    "read": {
      "uci": [ "singbox-ui" ],
      "ubus": { "singbox-ui": [ "myplugin_hello" ] }
    },
    "write": {
      "uci": [ "singbox-ui" ],
      "ubus": { "singbox-ui": [] }
    }
  }
}
```

Declare every method your plugin adds to the `singbox-ui` ubus object here.
The ACL-sync guard (`test_rpcd_acl_sync.test.ts`) unions **all** `acl.d/*.json`
files and verifies the union equals the handler's `list` output — so your
plugin's ACL file participates in the same guard automatically once both the
plugin and the core package are installed.

### i18n

A plugin may ship its own `.po` / `.lmo` files under a distinct i18n domain
(e.g. `singbox-ui-plugin-<name>`). The core domain `luci-singbox-ui` must
not be reused.

---

## Self-provisioning pattern

Some plugins depend on external components (a custom kernel module, a helper
binary, a feed from another vendor) that are not available in the standard
OpenWrt feeds at install time. Those components must not be listed in
`LUCI_DEPENDS`. Instead the plugin self-provisions them at runtime via a
**bash provisioning script**.

### Bash-script approach (recommended)

Ship a shell script at `root/usr/libexec/singbox-ui/<name>-provision.sh`.
The plugin's `init.uc` exposes a thin rpcd wrapper that runs the script;
the wrapper must capture the script's stdout so the rpcd JSON response stays
clean (the dispatcher writes one JSON line to stdout; any extra output
corrupts the response). Use an env seam (e.g. `SB_<NAME>_PROVISION`) to
override the script path in tests.

```sh
#!/bin/sh
# <name>-provision.sh — self-provision external feed components.
#
# Env seams (all have production defaults):
#   PROVISION_BIN  – path to this script (overridden in tests)
#   APK_CMD        – apk binary (default: apk)
#   WGET_CMD       – wget binary (default: wget)
#   KEYS_DIR       – destination for the signing key (default: /etc/apk/keys)
#   REPOS_D        – directory for the feed repo file (default: /etc/apk/repositories.d)
#   KEY_URL        – URL of the signing key PEM
#   FEED_BASE      – base URL of the feed (arch/version injected at runtime)
set -eu

APK_CMD="${APK_CMD:-apk}"
WGET_CMD="${WGET_CMD:-wget}"
KEYS_DIR="${KEYS_DIR:-/etc/apk/keys}"
REPOS_D="${REPOS_D:-/etc/apk/repositories.d}"
KEY_URL="${KEY_URL:-https://example.com/keys/myplugin.pem}"
FEED_BASE="${FEED_BASE:-https://example.com/feed}"

# 1. Detect OpenWrt version + target from /etc/openwrt_release.
. /etc/openwrt_release
VERSION="$DISTRIB_RELEASE"
TARGET="$DISTRIB_TARGET"    # format: <subtarget>/<arch>

# 2. Fetch the feed signing key dynamically (TOFU — operator accepts by clicking Install).
mkdir -p "$KEYS_DIR"
KEY_FILE="$KEYS_DIR/myplugin-feed.pem"
"$WGET_CMD" -q -O "$KEY_FILE" "$KEY_URL"

# 3. Idempotently add the feed to its OWN .list file.
REPO_FILE="$REPOS_D/myplugin.list"
REPO_URL="$FEED_BASE/$VERSION/$TARGET"
mkdir -p "$REPOS_D"
grep -qF "$REPO_URL" "$REPO_FILE" 2>/dev/null || printf '%s\n' "$REPO_URL" >> "$REPO_FILE"

# 4. apk update + install components.
"$APK_CMD" update
"$APK_CMD" add my-component-a my-component-b
```

Key points:

- **Dynamic key (TOFU).** Do not bundle the feed signing key in the plugin
  package. Fetch it at provision time via `wget`. The operator's explicit
  click of the "Install" button in the LuCI tab is the trust decision.
- **Idempotent feed line.** Use `grep -qF` to prevent duplicate entries in
  the `.list` file. Write the feed to its **own** file
  (`/etc/apk/repositories.d/<name>.list`), not to the global
  `/etc/apk/repositories`.
- **Suppress stdout.** The rpcd wrapper in `init.uc` must redirect the
  script's stdout to `/dev/null` (or capture it). Only stderr may propagate.
  Example wrapper (in `init.uc`):

  ```ucode
  myplugin_install: function () {
      let script = getenv("SB_MYPLUGIN_PROVISION") || "/usr/libexec/singbox-ui/myplugin-provision.sh";
      let rc = system(script + " >/dev/null");
      printf("%J\n", rc === 0
          ? { status: "ok" }
          : { status: "error", message: "provision script exited " + rc });
  },
  ```

### `plugin_install` core method

`ubus call singbox-ui plugin_install '{"package":"singbox-ui-plugin-<name>"}'`
installs a package from feeds **already configured** on the device. Use this
when the external component is already in a configured feed; use the
self-provisioning script when you need to add a new feed and fetch its key.

---

## Coverage-guard ownership

The core test suite guards the union of all installed `acl.d/*.json` files
against the handler's `list` output. A plugin that ships its own `acl.d` JSON
automatically participates in that guard when the plugin package is installed
alongside the core package in the test VM.

For parity and UI surface coverage a plugin should ship its own tests:

- **Parity tests** in `tests/parity/` — golden JSON for each new outbound
  type the plugin registers.
- **UI surface guard** — if the plugin adds browser-testable UI, an entry
  in `ui_surface.json` and a browser test with `export const COVERS`.
- **ACL assertion** — the plugin's own test suite verifies that its `acl.d`
  file is consistent with its rpcd handler registration.

The core `coverage_allowlist.txt` is the core's responsibility. A plugin must
not modify it.

---

## Invariants plugins must respect

| Invariant | Reason |
|---|---|
| Do not delete `route` or `outbounds` from the config. | sing-box rejects configs missing these keys. |
| Use a unique tag prefix (e.g. `myplugin-`) for any outbound you inject. | sing-box rejects duplicate tags. |
| Do not call back into LuCI/RPC from `on_generate_post`. | The hook runs synchronously inside rpcd; blocking calls stall the request. |
| Log errors via `require("log").log_event(...)`. | Consistent machine-readable format; plain `warn()` is acceptable for simple cases. |
| Plugin names are underscore-only (`^[a-z0-9_]+$`). | Dashes break ucode `require()` module resolution. |
| nft fragments must be complete `table <family> <name> { }` strings. | The full ruleset is applied atomically; partial fragments produce invalid nft input. |

---

## Reference: fixture plugin

`tests/fixtures/plugins/fixture_plugin/` is the canonical reference that
exercises every hook. It is not shipped in any manifest.

```
fixture_plugin/
  init.uc        — registers rpcd, lifecycle, nft, on_generate_post
  descriptor.uc  — registers a test outbound descriptor via try_register()
```

The skeleton under `docs/plugin-skeleton/` mirrors the flat layout used by
`plugins/awg_warp/`, with explanatory comments and no-op hook bodies. Copy
it with:

```sh
cp -r docs/plugin-skeleton plugins/<yourname>
# rename every occurrence of "skeleton" to your plugin name
```
