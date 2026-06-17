#!/bin/sh
# Tests lib/plugins/registry.uc: register / get_all / invoke order;
# hook exceptions logged not propagated.

set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-${SB_LIB}}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
    echo "SKIP test_plugins_registry (ucode missing)"
    exit 0
fi

"$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
    let r = require("plugins.registry");

    // Empty state.
    assert(length(r.get_all()) === 0, "registry starts empty");

    // Register two plugins.
    let calls = [];
    r.register({
        name: "a",
        on_generate_post: function(c, ctx) { push(calls, "a"); },
    });
    r.register({
        name: "b",
        on_generate_post: function(c, ctx) { push(calls, sprintf("b:%d", ctx.generation_ts)); },
    });

    assert(length(r.get_all()) === 2, "two plugins registered");

    // Invoke runs hooks in registration order.
    r.invoke_on_generate_post({}, { generation_ts: 42 });
    assert(join(",", calls) === "a,b:42", "invoke order: " + join(",", calls));

    // A throwing plugin must not break the chain.
    r.register({
        name: "boom",
        on_generate_post: function() { die("explode"); },
    });
    r.register({
        name: "after_boom",
        on_generate_post: function() { push(calls, "after_boom"); },
    });
    r.invoke_on_generate_post({}, { generation_ts: 43 });
    // "a", "b:43", "after_boom" should have been added (boom logged but not propagated).
    assert(index(calls, "after_boom") >= 0, "plugin after throwing plugin still ran");

    // Asserts on register contract.
    let bad_caught = false;
    try { r.register({ on_generate_post: function() {} }); }
    catch (_) { bad_caught = true; }
    assert(bad_caught, "register without name must throw");

    bad_caught = false;
    try { r.register({ name: "no_hook" }); }
    catch (_) { bad_caught = true; }
    assert(bad_caught, "register without on_generate_post must throw");

    print("PASS test_plugins_registry\n");
'
