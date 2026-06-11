#!/bin/sh
# tests/test_clash_route_helpers.sh — targeted unit tests for the three
# lib modules that had no direct coverage: clash.uc (feeds the clash_get/
# clash_mutate rpcd proxy target), route.uc (route.rules/final/referenced),
# and helpers.uc (rs-format detection, csv parsing, proxy-kind membership,
# iface-device env override, fnv1a32).
set -e
cd "$(dirname "$0")/.."

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"
	exit 0
fi

# uc EXPR — run a ucode snippet with the app lib on the search path and
# print whatever it prints. The snippet exits non-zero on assertion fail.
uc() { # shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e "$1"
}
ok() { echo "  PASS: $1"; }

echo "-- helpers.uc: detect_rs_format / csv_list / is_outbound_proxy_kind / fnv1a32"
uc '
let h = require("helpers");
function assert(c, m) { if (!c) { warn("ASSERT: " + m + "\n"); exit(1); } }
assert(h.detect_rs_format("https://x/a.srs", null)  === "binary", "srs->binary");
assert(h.detect_rs_format("https://x/a.json", null) === "source", "json->source");
assert(h.detect_rs_format("https://x/a.srs?v=1", null) === "binary", "query stripped");
assert(h.detect_rs_format("https://x/a.txt", "source") === "source", "override wins");
assert(length(h.csv_list("a, b ,c")) === 3, "csv 3 items");
assert(h.csv_list("a, b ,c")[1] === "b", "csv trims");
assert(length(h.csv_list("")) === 0, "empty csv -> []");
assert(h.is_outbound_proxy_kind("vless") === true, "vless is proxy kind");
assert(h.is_outbound_proxy_kind("vmess") === false, "vmess dropped in E2");
assert(h.is_outbound_proxy_kind("interface") === false, "interface not a proxy kind");
assert(length(h.fnv1a32("")) === 8, "fnv1a32 is 8 hex");
assert(h.fnv1a32("abc") === h.fnv1a32("abc"), "fnv1a32 deterministic");
print("ok\n");
' | grep -q '^ok$' || { echo "FAIL: helpers.uc assertions"; exit 1; }
ok "helpers.uc pure functions"

echo "-- helpers.uc: resolve_iface_device honours SINGBOX_DEV_<iface> env"
SINGBOX_DEV_wan=eth-test uc '
let h = require("helpers");
if (h.resolve_iface_device("wan") !== "eth-test") { warn("env override ignored\n"); exit(1); }
print("ok\n");
' | grep -q '^ok$' || { echo "FAIL: resolve_iface_device env override"; exit 1; }
ok "resolve_iface_device env override"

echo "-- clash.uc: build_clash_api defaults + IPv6 bracketing + disabled"
uc '
let m = require("clash");
function assert(c, msg) { if (!c) { warn("ASSERT: " + msg + "\n"); exit(1); } }
// Minimal cursor stub: build_clash_api only calls get_all(pkg, section).
function cur_for(section_obj) {
	return { get_all: function(_pkg, _sec) { return section_obj; } };
}
// disabled -> null
assert(m.build_clash_api(cur_for(null)) === null, "null section -> null");
assert(m.build_clash_api(cur_for({ enabled: "0" })) === null, "disabled -> null");
// enabled, defaults
let d = m.build_clash_api(cur_for({ enabled: "1" }));
assert(d.external_controller === "127.0.0.1:9090", "default addr");
assert(d.secret === undefined, "no secret when empty");
// custom listen/port + secret
let c = m.build_clash_api(cur_for({ enabled: "1", listen: "0.0.0.0", port: "9999", secret: "tok" }));
assert(c.external_controller === "0.0.0.0:9999", "custom addr");
assert(c.secret === "tok", "secret passed");
// IPv6 listen must be bracketed
let v6 = m.build_clash_api(cur_for({ enabled: "1", listen: "::1", port: "9090" }));
assert(v6.external_controller === "[::1]:9090", "ipv6 bracketed");
print("ok\n");
' | grep -q '^ok$' || { echo "FAIL: clash.uc assertions"; exit 1; }
ok "clash.uc build_clash_api"

echo "-- route.uc: hijack-dns + block->reject + disabled-ruleset drop + final"
uc '
let m = require("route");
function assert(c, msg) { if (!c) { warn("ASSERT: " + msg + "\n"); exit(1); } }
// Cursor stub: build_route_rules calls foreach(pkg, kind, fn) and
// get_all(pkg, "route_default"). foreach must invoke fn(section) for each
// section of the requested kind. We back it with in-memory arrays.
function cur_for(sections, route_default) {
	return {
		foreach: function(_pkg, kind, fn) {
			for (let s in (sections[kind] ?? [])) fn(s);
		},
		get_all: function(_pkg, sec) {
			return (sec === "route_default") ? route_default : null;
		}
	};
}
// tproxy inbound w/ hijack_dns -> protocol:dns hijack-dns rule
let r1 = m.build_route_rules(cur_for({
	inbound: [ { ".name": "tp", enabled: "1", protocol: "tproxy", hijack_dns: "1" } ],
}, null));
let saw_hijack = false;
for (let rule in r1.rules)
	if (rule.protocol === "dns" && rule.action === "hijack-dns") saw_hijack = true;
assert(saw_hijack, "tproxy hijack-dns rule emitted");
// route_rule action:block -> reject; referenced tracks enabled rulesets
let r2 = m.build_route_rules(cur_for({
	ruleset:    [ { ".name": "ads", enabled: "1" }, { ".name": "off", enabled: "0" } ],
	route_rule: [
		{ ".name": "r_block", enabled: "1", action: "block", ruleset: [ "ads" ] },
		{ ".name": "r_dead",  enabled: "1", action: "direct", ruleset: [ "off" ] },
	],
}, null));
let saw_reject = false;
for (let rule in r2.rules)
	if (rule.action === "reject") saw_reject = true;
assert(saw_reject, "block -> reject rule");
assert(length(r2.referenced) === 1 && r2.referenced[0] === "ads", "only enabled ruleset referenced");
// rule referencing only a disabled ruleset is dropped entirely
let only_direct = 0;
for (let rule in r2.rules) if (rule.action === "route") only_direct++;
assert(only_direct === 0, "rule over disabled-only ruleset dropped");
// route_default action:outbound -> final
let r3 = m.build_route_rules(cur_for({}, { action: "outbound", outbound: "wg0" }));
assert(r3.final === "wg0", "final from route_default outbound");
print("ok\n");
' | grep -q '^ok$' || { echo "FAIL: route.uc assertions"; exit 1; }
ok "route.uc build_route_rules"

echo "OK"
