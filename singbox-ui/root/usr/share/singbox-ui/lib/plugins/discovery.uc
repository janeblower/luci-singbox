// lib/plugins/discovery.uc — single place that finds and loads plugin entry
// points. Every discovery site (outbound.uc, rpcd handler, nftables.uc,
// apply-plugins.uc) calls load_all() so the glob + try/catch policy lives once.
// Idempotent: ucode require() caches, so repeat calls don't re-run a plugin.

let fs = require("fs");

// resolve the lib root: env override (tests) or the conventional prod path.
function lib_root(explicit) {
    if (explicit != null && length(explicit)) return explicit;
    let env = getenv("UCODE_APP_LIB_DIR");
    if (env != null && length(env)) return env;
    return "/usr/share/singbox-ui/lib";
}

function load_all(explicit) {
    let root = lib_root(explicit);
    let inits = fs.glob(root + "/plugins/*/init.uc");
    let loaded = 0;
    for (let path in (inits ?? [])) {
        // path = <root>/plugins/<name>/init.uc  → require name "plugins.<name>.init"
        let m = match(path, /\/plugins\/([^\/]+)\/init\.uc$/);
        if (!m) continue;
        let modname = "plugins." + m[1] + ".init";
        try { require(modname); loaded++; }
        catch (e) {
            try {
                require("log").log_event("warn", "plugin.load_failed",
                    { module: modname, err: ""+e });
            } catch (_) { warn(sprintf("discovery: %s failed: %s\n", modname, e)); }
        }
    }
    return loaded;
}

return { load_all, lib_root };
