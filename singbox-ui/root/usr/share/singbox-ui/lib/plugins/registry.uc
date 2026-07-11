// lib/plugins/registry.uc — plugin hook registry (Phase E).
//
// Plugins live under lib/plugins/<name>/init.uc (underscore-only name) and call
// register({...}) at module load. Discovery (lib/plugins/discovery.uc) require()s
// each init.uc; the backend/rpcd/nftables/apply sites pull the collected hooks.
// Hook errors are logged but never propagated — a misbehaving plugin must not
// break config generation, rpcd, or apply.
//
// See docs/plugins.md for the contract.

let _plugins = [];

// The UI's enable toggle (UCI singbox-ui.plugins.<name>_enabled) used to be read
// ONLY by the frontend and the `plugins` status method: discovery loaded every
// plugin unconditionally and every hook ran, so a plugin switched off in the UI
// kept creating its interface and NAT table on the next restart. The flag is
// enforced here, at the point where hooks take EFFECT, rather than in discovery —
// get_all() must keep listing installed-but-disabled plugins, otherwise the
// Plugins tab has nothing to offer the user to switch back on.
// Unset == disabled: a freshly installed plugin stays inert until enabled, which
// is what the frontend already assumed.
// Cached per NAME, not as one snapshot of the plugin list: plugins register at
// require() time, so a snapshot taken on the first lookup would treat everything
// registered afterwards as disabled.
let _enabled_cache = {};
function is_enabled(name) {
    if (_enabled_cache[name] == null) {
        let on = false;
        try {
            let uci = require("uci");
            let dir = getenv("UCI_CONFIG_DIR");
            let cur = dir ? uci.cursor(dir) : uci.cursor();
            on = (cur.get("singbox-ui", "plugins", name + "_enabled") === "1");
        } catch (_) {}
        _enabled_cache[name] = on;
    }
    return _enabled_cache[name] === true;
}

function _enabled_plugins() {
    let out = [];
    for (let p in _plugins) if (is_enabled(p.name)) push(out, p);
    return out;
}

function register(plugin) {
    assert(plugin.name != null, "plugin.name required");
    if (plugin.on_generate_post != null)
        assert(type(plugin.on_generate_post) === "function",
               "plugin.on_generate_post must be a function");
    if (plugin.rpcd != null)
        assert(type(plugin.rpcd.methods) === "object",
               "plugin.rpcd.methods must be an object");
    push(_plugins, plugin);
}

function get_all() { return _plugins; }

function get_rpcd_methods() {
    let out = {};
    for (let p in _enabled_plugins()) {
        if (p.rpcd == null || type(p.rpcd.methods) !== "object") continue;
        for (let name, fn in p.rpcd.methods) {
            if (out[name] != null)
                warn(sprintf("plugins.registry: rpcd method '%s' redefined by plugin '%s'\n", name, p.name));
            out[name] = fn;
        }
    }
    return out;
}

function get_lifecycle() {
    let out = [];
    for (let p in _enabled_plugins())
        if (p.lifecycle != null) push(out, { name: p.name,
            apply: p.lifecycle.apply, teardown: p.lifecycle.teardown });
    return out;
}

function get_nft_fragments() {
    let out = [];
    for (let p in _enabled_plugins())
        if (p.nft != null && type(p.nft.fragment) === "function")
            push(out, { name: p.name, fragment: p.nft.fragment });
    return out;
}

function invoke_on_generate_post(config, ctx) {
    for (let p in _enabled_plugins()) {
        if (type(p.on_generate_post) !== "function") continue;
        try { p.on_generate_post(config, ctx); }
        catch (e) {
            try {
                require("log").log_event("error", "plugin.hook_failed",
                    { plugin: p.name, hook: "on_generate_post", err: ""+e });
            } catch (_) {}
        }
    }
}

// No get_rpcd_acl(): it aggregated plugin acl_read/acl_write lists that nothing
// ever consumed — plugins ship their own acl.d/*.json, which is what rpcd reads.

return { register, get_all, is_enabled, get_rpcd_methods,
         get_lifecycle, get_nft_fragments, invoke_on_generate_post };
