#!/usr/bin/ucode
// generate.uc — read UCI and emit the sing-box config JSON. Orchestration only;
// all section builders live in /usr/share/singbox-ui/lib/*.uc and are loaded
// via `-L` (set by the init.d, rpcd, and cron wrappers).
//
// Env overrides (tests/init.d):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)  — consumed by lib/outbound.uc
//   SINGBOX_CONFIG (default /tmp/singbox-ui.json) — output path
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

const CONFIG_OUT = getenv("SINGBOX_CONFIG") || "/tmp/singbox-ui.json";

let uci_dir = getenv("UCI_CONFIG_DIR");
let uci = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
let fs  = require("fs");

let log_mod      = require("log");
let dns_mod      = require("dns");
let inbound_mod  = require("inbound");
let outbound_mod = require("outbound");
let route_mod    = require("route");
let ruleset_mod  = require("ruleset");
let cache_mod    = require("cache");
let clash_mod    = require("clash");

let config = {};

let log_block = log_mod.build_log(uci);
if (log_block) config.log = log_block;

let dns_block = dns_mod.build_dns(uci);
if (dns_block) config.dns = dns_block;

let in_block = inbound_mod.build_inbounds(uci);
if (length(in_block)) config.inbounds = in_block;

let out_block = outbound_mod.build_outbounds(uci);

// route.rules / route_default / dns.detour reference outbound TAGS — "direct"
// and "block" included. sing-box 1.11+ no longer provides implicit outbounds,
// so inject them here unless a user outbound already claims the tag.
let have_direct = false, have_block = false;
for (let o in out_block) {
	if (o.tag === "direct") have_direct = true;
	if (o.tag === "block")  have_block  = true;
}
if (!have_direct) push(out_block, { tag: "direct", type: "direct" });
if (!have_block)  push(out_block, { tag: "block",  type: "block"  });

config.outbounds = out_block;

let r = route_mod.build_route_rules(uci);
let rsets = ruleset_mod.build_rule_sets(uci, r.referenced);
if (length(rsets) || length(r.rules) || r.final) {
	config.route = {};
	if (length(rsets))   config.route.rule_set = rsets;
	if (length(r.rules)) config.route.rules    = r.rules;
	if (r.final)         config.route.final    = r.final;
}

let experimental = {};
let cache_block = cache_mod.build_cache(uci);
if (cache_block) experimental.cache_file = cache_block;
let clash_block = clash_mod.build_clash_api(uci);
if (clash_block) experimental.clash_api = clash_block;
if (length(keys(experimental))) config.experimental = experimental;

let f = fs.open(CONFIG_OUT, "w");
if (!f) {
	warn(`generate.uc: cannot open ${CONFIG_OUT} for writing\n`);
	exit(1);
}
f.write(sprintf("%.4J\n", config));
f.close();

print("OK\n");
