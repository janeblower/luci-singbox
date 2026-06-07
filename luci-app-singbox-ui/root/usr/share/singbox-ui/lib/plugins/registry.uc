// lib/plugins/registry.uc — plugin hook registry (Phase D scaffolding).
//
// Plugins live under lib/plugins/<name>.uc and call register({name, on_generate_post})
// at module load. lib/post_process.uc::run_pipeline invokes registered hooks
// after implicit-direct scrubbing. Hook errors are logged but never propagated:
// a misbehaving plugin must not break config generation.
//
// See docs/plugins.md for the contract.

let _plugins = [];

function register(plugin) {
    assert(plugin.name != null, "plugin.name required");
    assert(type(plugin.on_generate_post) === "function",
           "plugin.on_generate_post must be a function");
    push(_plugins, plugin);
}

function get_all() { return _plugins; }

function invoke_on_generate_post(config, ctx) {
    for (let p in _plugins) {
        try { p.on_generate_post(config, ctx); }
        catch (e) {
            try {
                require("log").log_event("error", "plugin.hook_failed",
                    { plugin: p.name, hook: "on_generate_post", err: ""+e });
            } catch (_) {}
        }
    }
}

return { register, get_all, invoke_on_generate_post };
