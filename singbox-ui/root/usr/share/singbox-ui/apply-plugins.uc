#!/usr/bin/ucode
// apply-plugins.uc — run plugin lifecycle hooks. Invoked by init.d in the apply
// path (under the lifecycle-lock) and on stop. Hooks must be idempotent;
// failures are logged, never fatal (one bad plugin can't wedge the daemon).
//
//   apply-plugins.uc apply      → each plugin lifecycle.apply(cur)
//   apply-plugins.uc teardown   → each plugin lifecycle.teardown(cur)

"use strict";

let uci = require("uci");

function run(phase) {
    let cur = uci.cursor();
    let disc = require("plugins.discovery");
    disc.load_all();
    let lcs = require("plugins.registry").get_lifecycle();
    for (let lc in lcs) {
        let fn = (phase === "apply") ? lc.apply : lc.teardown;
        if (type(fn) !== "function") continue;
        try { fn(cur); }
        catch (e) {
            try { require("log").log_event("error", "plugin.hook_failed",
                { plugin: lc.name, hook: "lifecycle." + phase, err: ""+e }); }
            catch (_) { warn(sprintf("apply-plugins: %s.%s failed: %s\n", lc.name, phase, e)); }
        }
    }
}

let phase = ARGV[0] || "";
if (phase !== "apply" && phase !== "teardown") {
    warn("Usage: apply-plugins.uc {apply|teardown}\n");
    exit(1);
}
run(phase);
exit(0);
