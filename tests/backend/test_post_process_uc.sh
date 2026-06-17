#!/bin/sh
# tests/test_post_process_uc.sh
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
run_uc() { "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" -e "$1"; }

# GEN-2: dns detour to the implicit `direct` is ALWAYS scrubbed (sing-box
# rejects detour to the implicit/empty direct). But a route rule / final naming
# `direct` when it IS a real injected outbound must be KEPT — routing TO direct
# is valid sing-box, and stripping it would leave a route action with no
# outbound. The route scrub only fires for an implicit tag that does NOT resolve
# to a real outbound (truly dangling).
echo "-- scrub_implicit_refs: dns detour scrubbed; route ref to real implicit direct kept"
out=$(run_uc '
	let pp = require("post_process");
	let cfg = {
		outbounds: [{ type: "direct", tag: "direct" }],
		dns: { servers: [{ tag: "ns1", detour: "direct" }] },
		route: { final: "direct", rules: [{ outbound: "direct" }] }
	};
	let r = pp.scrub_implicit_refs(cfg, { implicit_tags: ["direct"] });
	print(((r.dns.servers[0].detour ?? "(absent)") == "(absent)" || r.dns.servers[0].detour === null ? "scrubbed" : r.dns.servers[0].detour) + "\n");
	print(((r.route.final ?? "(absent)") == "(absent)" || r.route.final === null ? "scrubbed" : r.route.final) + "\n");
	print(((r.route.rules[0].outbound ?? "(absent)") == "(absent)" || r.route.rules[0].outbound === null ? "scrubbed" : r.route.rules[0].outbound) + "\n");
')
[ "$out" = "scrubbed
direct
direct" ] && echo "  PASS: dns detour scrubbed, route ref to real direct kept" || { echo "FAIL: [$out]"; exit 1; }

echo "-- scrub_implicit_refs: route ref to a DANGLING implicit tag IS scrubbed"
out=$(run_uc '
	let pp = require("post_process");
	let cfg = {
		outbounds: [{ type: "vless", tag: "p" }],
		route: { final: "ghost", rules: [{ outbound: "ghost" }] }
	};
	let r = pp.scrub_implicit_refs(cfg, { implicit_tags: ["ghost"] });
	print(((r.route.final ?? "(absent)") == "(absent)" || r.route.final === null ? "scrubbed" : r.route.final) + "\n");
	print(((r.route.rules[0].outbound ?? "(absent)") == "(absent)" || r.route.rules[0].outbound === null ? "scrubbed" : r.route.rules[0].outbound) + "\n");
')
[ "$out" = "scrubbed
scrubbed" ] && echo "  PASS: dangling implicit route refs scrubbed" || { echo "FAIL: [$out]"; exit 1; }

echo "-- scrub_implicit_refs no-op when implicit_tags empty"
out=$(run_uc '
	let pp = require("post_process");
	let r = pp.scrub_implicit_refs({
		dns: { servers: [{ tag: "ns1", detour: "direct" }] }
	}, { implicit_tags: [] });
	print(r.dns.servers[0].detour);
')
[ "$out" = "direct" ] && echo "  PASS: no scrub when no implicit" || { echo "FAIL: [$out]"; exit 1; }

echo "-- run_pipeline is idempotent"
out=$(run_uc '
	let pp = require("post_process");
	let cfg = { dns: { servers: [{ tag: "n", detour: "direct" }] } };
	pp.run_pipeline(cfg, { implicit_tags: ["direct"] });
	pp.run_pipeline(cfg, { implicit_tags: ["direct"] });
	print(cfg.dns.servers[0].detour === null || cfg.dns.servers[0].detour === undefined ? "scrubbed" : cfg.dns.servers[0].detour);
')
[ "$out" = "scrubbed" ] && echo "  PASS: pipeline idempotent" || { echo "FAIL: [$out]"; exit 1; }

# D4.4: post_process.run_pipeline must invoke registered plugin hooks.
# Load the test-only noop plugin from tests/fixtures/plugins via a second -L,
# then assert _test_noop_called was set during run_pipeline.
echo "-- run_pipeline invokes registered plugin hooks (noop fixture)"
out=$("$UCODE_BIN" \
    -L "$UCODE_APP_LIB_DIR" \
    -L "$PWD/tests/fixtures" \
    -e '
        require("plugins.noop");
        let pp = require("post_process");
        pp.run_pipeline({ route: { rules: [] } }, { generation_ts: 12345 });
        assert(global._test_noop_called != null, "noop plugin not invoked");
        assert(global._test_noop_called.ts === 12345, "ctx.generation_ts not passed");
        assert(global._test_noop_called.had_config === true, "config not passed");
        print("PASS test_post_process_uc plugin invocation\n");
    ')
[ "$out" = "PASS test_post_process_uc plugin invocation" ] && echo "  PASS: plugin hook invoked by run_pipeline" || { echo "FAIL: [$out]"; exit 1; }

echo "ALL PASS"
