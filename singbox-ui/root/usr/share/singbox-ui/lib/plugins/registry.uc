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
    for (let p in _plugins) {
        if (p.rpcd == null || type(p.rpcd.methods) !== "object") continue;
        for (let name, fn in p.rpcd.methods) {
            if (out[name] != null)
                warn(sprintf("plugins.registry: rpcd method '%s' redefined by plugin '%s'\n", name, p.name));
            out[name] = fn;
        }
    }
    return out;
}

function get_rpcd_acl() {
    let read = [], write = [];
    for (let p in _plugins) {
        if (p.rpcd == null) continue;
        for (let m in (p.rpcd.acl_read ?? []))  push(read, m);
        for (let m in (p.rpcd.acl_write ?? [])) push(write, m);
    }
    return { read, write };
}

function get_lifecycle() {
    let out = [];
    for (let p in _plugins)
        if (p.lifecycle != null) push(out, { name: p.name,
            apply: p.lifecycle.apply, teardown: p.lifecycle.teardown });
    return out;
}

function get_nft_fragments() {
    let out = [];
    for (let p in _plugins)
        if (p.nft != null && type(p.nft.fragment) === "function")
            push(out, { name: p.name, fragment: p.nft.fragment });
    return out;
}

function invoke_on_generate_post(config, ctx) {
    for (let p in _plugins) {
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

return { register, get_all, get_rpcd_methods, get_rpcd_acl,
         get_lifecycle, get_nft_fragments, invoke_on_generate_post };
