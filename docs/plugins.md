# Plugin API (Phase D scaffolding)

A minimal extension point that lets operator-trusted code mutate the generated sing-box config after the core builders run. The Phase D surface is deliberately small — one hook (`on_generate_post`), one registry function (`register`), no UCI or RPC surface for managing plugins. Phase E may extend.

## Contract

A plugin is a ucode module under `/usr/share/singbox-ui/lib/plugins/<name>.uc`. On `require()` it calls:

```ucode
let reg = require("plugins.registry");

reg.register({
    name: "my_plugin",       // required, string; used in audit/error logs
    on_generate_post: function(config, ctx) {
        // ...mutate config in place (or no-op)...
    },
});

return {};   // return value is discarded by the eager-loader
```

### `on_generate_post(config, ctx)`

Called exactly once per `generate.uc` run, after `lib/post_process.uc::scrub_implicit_refs` removes implicit-direct references but before the JSON is serialized to `/tmp/singbox-ui.json`.

| Argument | Shape |
|---|---|
| `config` | The complete sing-box config object (`{log, dns, inbounds, outbounds, route, experimental, ...}`). Plugins may mutate it in place. |
| `ctx` | `{ implicit_tags: [...] }` — the same `opts` object that `run_pipeline` receives. May be extended in future without breaking plugins (additive only). |

The function MUST NOT throw. If it does, the exception is caught and logged via `log_event("error", "plugin.hook_failed", {plugin, hook, err})`; the rest of the plugin chain still runs and the generated config is emitted as-is up to that point.

### Invariants plugins must respect

| Invariant | Why |
|---|---|
| Do not delete `route` or `outbounds`. | sing-box rejects configs without these. There is no test-time enforcement (a plugin can technically do it); operators who break this WILL see `sing-box check` fail in `tests/test_generate.sh` (Docker) or at apply time. |
| Do not introduce duplicate tags. | sing-box rejects on duplicate `outbounds[].tag`. Use a unique prefix (e.g. `myplugin-<tag>`). |
| Do not call back into LuCI/RPC. | The plugin runs inside `generate.uc`, which runs synchronously inside rpcd. Network calls or other sync ops will stall the request. |
| Errors via `lib/log::log_event`. | Same machine-readable format as the rest of the codebase. Plain `warn()` is acceptable too. |

## Discovery

`generate.uc` calls `fs.glob("/usr/share/singbox-ui/lib/plugins/*.uc")` on startup and `require()`s every match except `registry.uc`. Each `require` is wrapped in `try/catch` — a syntactically broken plugin file is logged via `log_event("warn", "plugin.load_failed", {module, err})` and skipped; the rest of the chain still loads.

There is **no RPC method** that installs, activates, or lists plugins. Management is purely "drop a file under `/usr/share/singbox-ui/lib/plugins/` and apply". This is intentional for Phase D — see "Threat model" below.

## Threat model

Plugins are **trusted code**. Putting a file under `/usr/share/singbox-ui/lib/plugins/` requires write access to the rootfs, which already implies the operator has root on the router. Granting that access to a plugin runtime adds no new attack surface.

What the Phase D plugin API explicitly does NOT do:
- Sandbox plugin execution.
- Restrict which sing-box config keys plugins can modify.
- Authenticate or sign plugins.
- Surface plugins to LuCI for install/enable/disable from the web UI.
- Expose a plugin registry over the network.

Phase E may add some of these if a concrete plugin ecosystem develops. For Phase D the assumption is: zero or one author, the same person who built the router image, who has root anyway.

## Example: noop plugin

The reference implementation is `tests/fixtures/plugins/noop.uc` (not shipped):

```ucode
let reg = require("plugins.registry");

reg.register({
    name: "noop",
    on_generate_post: function(config, ctx) {
        global._test_noop_called = {
            ts: (ctx != null ? ctx.generation_ts : null),
            had_config: (config != null),
        };
    },
});

return {};
```

It registers, records its invocation, mutates nothing. `tests/test_post_process_uc.sh` loads it via `-L tests/fixtures` and asserts the registry actually invokes it during `run_pipeline`.

## Installation manifest invariant

`tests/test_install_manifest_fresh.sh` enforces that the production manifest contains EXACTLY ONE file under `lib/plugins/` — the registry itself. Any in-tree plugin must be moved into a separate package or explicitly added to `scripts/install-manifest-overrides.txt` with a clear "Phase D ships nothing" exception.
