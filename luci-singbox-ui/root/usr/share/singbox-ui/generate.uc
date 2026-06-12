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

let helpers      = require("helpers");
let log_mod      = require("log");
let dns_mod      = require("dns");
let inbound_mod  = require("inbound");
let outbound_mod = require("outbound");
let route_mod    = require("route");
let ruleset_mod  = require("ruleset");
let cache_mod    = require("cache");
let clash_mod    = require("clash");

// Wipe the iface→netdev memoisation table held inside lib/helpers.uc. A
// long-lived ucode process (e.g. rpcd worker that imports this module once
// and re-invokes it across config reloads) would otherwise serve stale
// mappings if /etc/config/network was edited between runs. The cost is
// negligible — the table is small and re-populated lazily on demand.
helpers.reset_iface_cache();

let config = {};

let log_block = log_mod.build_log(uci);
if (log_block) config.log = log_block;

let dns_block = dns_mod.build_dns(uci);
if (dns_block) config.dns = dns_block;

let in_block = inbound_mod.build_inbounds(uci);
if (length(in_block)) config.inbounds = in_block;

let out_block = outbound_mod.build_outbounds(uci);

// route.rules / route_default / dns.detour reference outbound TAGS — sing-box
// 1.11+ no longer provides an implicit `direct` outbound, so inject one when
// the user hasn't defined their own. The `block` outbound was removed in 1.11;
// route.uc emits `action: "reject"` rules instead, so nothing to inject here.
let post_process = require("post_process");

// D4: eagerly load any plugins present under /usr/share/singbox-ui/lib/plugins/*.uc.
// Each plugin's register() call fires on require. Failures are logged but never
// fatal — a broken plugin file must not stop config generation.
let plugin_files = fs.glob("/usr/share/singbox-ui/lib/plugins/*.uc") || [];
for (let path in plugin_files) {
	if (match(path, /\/registry\.uc$/)) continue;
	let m = match(path, /\/([^\/]+)\.uc$/);
	if (!m) continue;
	let modname = "plugins." + m[1];
	try { require(modname); }
	catch (e) {
		try { log_mod.log_event("warn", "plugin.load_failed",
		                        { module: modname, err: ""+e }); }
		catch (_) {}
	}
}

let have_direct = false;
for (let o in out_block) {
	if (o.tag === "direct") have_direct = true;
}

let implicit_tags = [];
if (!have_direct) {
	push(out_block, { tag: "direct", type: "direct" });
	push(implicit_tags, "direct");
}

config.outbounds = out_block;

// Centralised post-processing pipeline. See lib/post_process.uc.
config = post_process.run_pipeline(config, { implicit_tags: implicit_tags });

// S3.2: the set of outbound tags that actually exist in the final outbounds[]
// (disabled/deleted ones are already excluded by outbound.uc). route.uc uses it
// to drop route_rule/route_default outbound references that don't resolve,
// rather than emitting a dangling tag that makes sing-box refuse to start.
let valid_ob = {};
for (let o in config.outbounds) if (length(o.tag)) valid_ob[o.tag] = true;

let r = route_mod.build_route_rules(uci, valid_ob);
// S3.1: route.rule_set must DEFINE every rule-set tag referenced anywhere —
// route rules AND dns rules. route.uc reports only route-referenced rulesets,
// so union in the dns-referenced ones (deduped) before building definitions;
// otherwise a ruleset used solely by a dns_rule is emitted as a dangling tag
// and sing-box refuses to start ("rule-set not found").
let referenced = r.referenced;
let ref_seen = {};
for (let n in referenced) ref_seen[n] = true;
for (let n in dns_mod.referenced_rulesets(uci))
	if (!ref_seen[n]) { push(referenced, n); ref_seen[n] = true; }
let rsets = ruleset_mod.build_rule_sets(uci, referenced);
if (length(rsets) || length(r.rules) || r.final) {
	config.route = {};
	if (length(rsets))   config.route.rule_set = rsets;
	if (length(r.rules)) config.route.rules    = r.rules;
	if (r.final)         config.route.final    = r.final;
}

// sing-box 1.12 warns "missing route.default_domain_resolver ... will be
// removed in sing-box 1.14". Resolve here: honour an explicit UCI
// `dns.default_resolver` tag if present; otherwise auto-pick the first
// enabled non-fakeip dns_server. Skipped if no resolver candidate exists.
// S3.3: do NOT gate this on config.route already existing. A config with DNS
// servers but no route_rules/rulesets/route_default produces no route block,
// which would skip the resolver and reintroduce the very 1.12 deprecation
// warning (1.14 hard failure) this code exists to suppress. When a resolver
// candidate exists, create a minimal route block to carry it.
if (type(config.dns) === "object" && type(config.dns.servers) === "array") {
	let dns_section = uci.get_all("singbox-ui", "dns");
	let resolver_tag = dns_section ? dns_section.default_resolver : null;
	if (resolver_tag == null || resolver_tag === "") {
		for (let s in config.dns.servers) {
			if (s.type !== "fakeip" && length(s.tag)) { resolver_tag = s.tag; break; }
		}
	}
	if (resolver_tag != null && length(resolver_tag)) {
		if (!config.route) config.route = {};
		config.route.default_domain_resolver = { server: resolver_tag };
	}
}

let experimental = {};
let cache_block = cache_mod.build_cache(uci);
if (cache_block) experimental.cache_file = cache_block;
let clash_block = clash_mod.build_clash_api(uci);
if (clash_block) experimental.clash_api = clash_block;
if (length(keys(experimental))) config.experimental = experimental;

// Atomic publish: write to <CONFIG_OUT>.tmp.<entropy>, then fs.rename to
// CONFIG_OUT. On any failure, unlink the tmp. Keeps a <CONFIG_OUT>.prev
// backup of the previous file so an operator can roll back manually.
//
// Crash-safety: a SIGKILL between fs.open and fs.rename leaves an orphan
// tmpfile (which a subsequent successful run will replace, not stat); but
// never a truncated CONFIG_OUT that sing-box would refuse to start with.
// This is the file analog of preview_tmp() in rpcd/singbox-ui.
//
// Entropy: 4 bytes from /dev/urandom mixed with time(). On the off chance
// /dev/urandom is unavailable, fall back to time() alone — collisions are
// harmless because fs.rename over the tmp is atomic regardless.
function publish_atomic(path, body) {
	let n = 0;
	let r;
	try { r = fs.open("/dev/urandom", "r"); } catch (_) { r = null; }
	if (r) {
		let b = r.read(4) ?? "";
		r.close();
		for (let i = 0; i < length(b); i++) n = n * 256 + ord(b, i);
	}
	let tmp = sprintf("%s.tmp.%d.%d", path, time(), n);

	let f = fs.open(tmp, "w");
	if (!f) {
		warn(sprintf("generate.uc: cannot open tmpfile %s for writing\n", tmp));
		return false;
	}
	let ok = true;
	try { f.write(body); } catch (_) { ok = false; }
	f.close();
	if (!ok) {
		warn(sprintf("generate.uc: write to %s failed\n", tmp));
		try { fs.unlink(tmp); } catch (_) {}
		return false;
	}

	// Best-effort backup of the previous file. Ignore failures (file may
	// not exist on first run, or the rename may not be permitted).
	let prev = path + ".prev";
	try { fs.unlink(prev); } catch (_) {}
	try { fs.rename(path, prev); } catch (_) {}

	let renamed = false;
	try { renamed = fs.rename(tmp, path); } catch (_) { renamed = false; }
	if (!renamed) {
		warn(sprintf("generate.uc: rename %s -> %s failed\n", tmp, path));
		try { fs.unlink(tmp); } catch (_) {}
		return false;
	}
	return true;
}

// Object key emission order (emitters put `type`/`tag` first) relies on ucode
// preserving object insertion order through %.4J — guaranteed by ucode's
// insertion-ordered objects, and load-bearing for test_generate.sh's
// positional assertions and diff stability (S1.3). Array order (route rules,
// outbounds) is the genuinely correctness-critical ordering and is safe via
// push(). A future serializer swap or keys()-rebuild refactor could reorder
// keys and break tests confusingly — keep this property in mind.
if (!publish_atomic(CONFIG_OUT, sprintf("%.4J\n", config))) {
	exit(1);
}

// C3.3 / S1.1 / S1.2: record GENERATE state for status_detail RPC, atomically
// (publish_atomic, same durability as the main config — no truncated read).
// This records only that a well-formed config was WRITTEN, NOT that sing-box
// accepted and is running it; hence `last_generate_result`. The real apply
// outcome is written by the init.d start path to apply_state.json
// (last_apply_result) after a successful `sing-box check`.
try {
	fs.mkdir("/var/lib/singbox-ui", 0755);
	publish_atomic("/var/lib/singbox-ui/last_state.json",
		sprintf("{\"last_generate_ts\":%d,\"last_generate_result\":\"ok\",\"config_hash\":\"unknown\"}", time()));
} catch (_) {}

try { log_mod.log_event("info", "config.generated", {}); } catch (_) {}

print("OK\n");
