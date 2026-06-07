// Test-only plugin. NOT shipped in production manifest.
// Used by tests/test_post_process_uc.sh to confirm run_pipeline invokes
// registered hooks.

let reg = require("plugins.registry");

reg.register({
    name: "noop",
    on_generate_post: function(config, ctx) {
        // Side effect: record invocation in a global so the test can read it.
        global._test_noop_called = {
            ts: (ctx != null ? ctx.generation_ts : null),
            had_config: (config != null),
        };
    },
});

return {};
