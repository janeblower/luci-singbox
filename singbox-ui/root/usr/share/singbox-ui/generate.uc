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

// last_state.json describes the state of the PRODUCTION config, so only a run
// that writes the production config may touch it. SINGBOX_CONFIG is set solely by
// the rpcd preview path (and by tests): preview is a read-ACL method, yet it used
// to overwrite last_state.json unconditionally — faking Monitoring's "generated
// ok" and erasing a write_failed_stale marker that says the daemon is running an
// out-of-date config.
const IS_PROD_OUT = (getenv("SINGBOX_CONFIG") == null);

// init.d's __do_start inspects this rc to decide whether the OLD
// /tmp/singbox-ui.json (still on disk — every failure path below bails
// BEFORE touching CONFIG_OUT) is safe to hand to procd. This is the ONLY
// generate.uc failure that means "this config has no defined meaning, do not
// run it" — every OTHER failure (see publish_atomic's caller, near the
// bottom of this file) means "couldn't write a NEW config, but the old one
// is still good" and deliberately keeps plain exit(1), because init.d must
// fall through to its own guards ([ ! -s /tmp/singbox-ui.json ] and
// `sing-box check`) and start on the stale-but-valid file rather than take
// the whole proxy down over a transient write failure (disk pressure) on a
// 15-minute cron reload.
const EXIT_TRANSPARENT_CONFLICT = 3;

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

// Two interceptors on one LAN is not a config with a defined meaning: a tproxy
// inbound owning our `inet singbox_ui` table AND a tun inbound owning auto_route
// both claim the same traffic, and which one wins comes down to nft hook order.
// `sing-box check` cannot catch it — both halves are individually valid — so the
// invariant is ours to guard. The UI disables the loser's checkbox, so getting
// here means UCI was edited by hand.
//
// Refuse loudly instead of writing a config whose behaviour we cannot predict. We
// bail BEFORE touching CONFIG_OUT, so the last known-good config survives and the
// daemon keeps running on it; init.d turns this non-zero exit into a refusal to
// (re)start rather than starting on the stale file.
//
// The REMEDY has to ride in the log_event payload, not only in warn(): warn()
// writes to stderr, and on both paths that reach this code stderr is gone —
// procd does not route a start_service child's stderr to syslog, and rpcd's
// wrappers append `>/dev/null 2>&1`. log_event popens `logger` itself, so it is
// the only channel the operator actually reads.
let tconf = helpers.transparent_conflict(uci);
if (tconf != null) {
	let fix = sprintf("disable nft_rules on inbound '%s' or auto_route on inbound '%s'", tconf.tproxy, tconf.tun);
	warn(sprintf("generate.uc: refusing to build — inbound '%s' (tproxy nft rules) and inbound '%s' (tun auto_route) both claim system routing. Exactly one may. To fix: %s.\n",
		tconf.tproxy, tconf.tun, fix));
	try { log_mod.log_event("error", "config.transparent_conflict",
		{ tproxy: tconf.tproxy, tun: tconf.tun, fix: fix }); } catch (_) {}
	exit(EXIT_TRANSPARENT_CONFLICT);
}

// `generate.uc check-conflict` — run ONLY the guard above, then stop. Nothing is
// built, nothing is written; the rc is the same EXIT_TRANSPARENT_CONFLICT.
//
// init.d's reload_service asks this BEFORE it stops the daemon. It used to be
// plain `stop; start`: `stop` removes our `inet singbox_ui` table, and `start`
// then ran the full generate.uc, got rc 3 and refused — so a conflicting UCI (a
// */15 cron reload, or the UI's Apply) left the box with NO sing-box and NO
// interception, and the LAN egressed unproxied. We refused, we logged, and the
// traffic leaked anyway. Asking first means a bad edit is refused as an APPLY:
// the daemon keeps serving the last known-good config, table intact.
//
// It is a MODE of this entrypoint rather than a predicate init.d could evaluate
// itself, because the rule already lives in exactly one place
// (helpers.transparent_conflict, consumed here) and a second copy in shell would
// drift. ARGV dispatch mirrors `nftables.uc needed` / `subscription.uc fetch-subs`.
if (ARGV[0] === "check-conflict") exit(0);

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

// Plugin descriptors are loaded by require("outbound") above, which calls
// plugins.discovery.load_all(). The loop that used to live here globbed the old
// FLAT lib/plugins/*.uc layout; plugins ship as plugins/<name>/init.uc dirs now,
// so it never matched anything and was dead code.

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
// Third source: a tun inbound's route_address_set / route_exclude_address_set.
// sing-box resolves those tags itself and refuses the whole config on a dangling
// one, exactly as it does for a dns-only reference. Fed the BUILT inbounds (not
// the cursor) so the set defined here cannot drift from the set actually emitted
// — see inbound.uc referenced_rulesets().
for (let n in inbound_mod.referenced_rulesets(in_block))
	if (!ref_seen[n]) { push(referenced, n); ref_seen[n] = true; }
// An enabled inline rule-set that nothing references is dead config: it is not
// emitted (build_rule_sets only builds referenced sets), yet route.uc still
// suppresses its member default rules from top-level emission. Warn so the
// "vanished rules" surprise is diagnosable (the UI also badges them inline:X).
uci.foreach("singbox-ui", "ruleset", function(s) {
	if (s.enabled === "0") return;
	if ((s.type ?? "remote") !== "inline") return;
	if (!ref_seen[s[".name"]])
		warn(sprintf("generate.uc: inline rule-set '%s' is enabled but unreferenced; its member rules are not applied\n", s[".name"]));
});
let rsets = ruleset_mod.build_rule_sets(uci, referenced, valid_ob);
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
	let server_tags = {};
	for (let s in config.dns.servers) if (length(s.tag)) server_tags[s.tag] = true;
	let dns_section = uci.get_all("singbox-ui", "dns");
	let resolver_tag = dns_section ? dns_section.default_resolver : null;
	// An explicit default_resolver must name an enabled dns_server; the UI
	// ListValue keeps a stale value after that server is disabled/deleted, which
	// would emit a dangling default_domain_resolver and make sing-box hard-fail.
	if (length(resolver_tag ?? "") && !server_tags[resolver_tag]) {
		warn(sprintf("generate.uc: dns.default_resolver '%s' is not an enabled dns_server; auto-picking\n", resolver_tag));
		resolver_tag = null;
	}
	if (resolver_tag == null || resolver_tag === "") {
		// Only a general-purpose upstream resolver can serve as the domain
		// resolver. hosts/dhcp/mdns/tailscale/resolved/fakeip cannot resolve
		// arbitrary domains (they would loop or fail), so restrict the
		// auto-pick to resolving types — plus a legacy server (empty type,
		// <=1.13) which resolves via its address. Fall through to NO resolver
		// if none qualify (safer than a non-resolving pick).
		let resolver_types = { udp: true, tcp: true, tls: true, quic: true, https: true, h3: true, local: true };
		for (let s in config.dns.servers) {
			if (length(s.tag) && (resolver_types[s.type] || !length(s.type ?? ""))) {
				resolver_tag = s.tag; break;
			}
		}
	}
	if (resolver_tag != null && length(resolver_tag)) {
		if (!config.route) config.route = {};
		config.route.default_domain_resolver = { server: resolver_tag };
	}
}

// Package-owned outbound tags (`builtin '1'` — today just `wan`). The pipeline
// drops the ones nothing references: the built-in WAN outbound exists to give the
// Default route a sane target, and must not linger in the config (or on the
// Dashboard) once the user has routed somewhere else — they cannot delete it
// themselves, the UI locks builtin rows.
let builtin_tags = {};
uci.foreach("singbox-ui", "outbound", function(s) {
	if (s.builtin === "1") builtin_tags[s[".name"]] = true;
});

// Centralised post-processing pipeline. See lib/post_process.uc.
// GEN-2: must run AFTER config.route is fully assembled (route rules/final +
// default_domain_resolver above) — at the previous call site (right after
// config.outbounds) config.route did not exist yet, so the route-rule/final
// implicit-ref scrub branches were dead code. The scrub only mutates dns/route
// references, never config.outbounds, so the valid_ob set built above is
// unaffected; plugins' on_generate_post now also see the complete config.
config = post_process.run_pipeline(config, {
	implicit_tags: implicit_tags,
	builtin_tags:  builtin_tags,
});

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
// Write errors: ucode's fs.file.write() does NOT throw — it RETURNS null (and
// close() returns true regardless, flush error swallowed). A `try { f.write() }
// catch` is therefore inert: under ENOSPC it used to return true with a
// truncated tmp, rename the last known-good config aside to .prev, and publish
// the truncated one — with last_generate_result "ok". Check both write() and
// flush(): write() catches a mid-write buffer flush failing, flush() catches a
// body small enough to sit entirely in the buffer (where the error would
// otherwise surface only at close(), which lies).
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
	let ok = false;
	try { ok = (f.write(body) != null && f.flush() != null); } catch (_) { ok = false; }
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
	// missed-7: a failed write must not look like a clean generate. If
	// CONFIG_OUT still exists (the early open/write failure path leaves the
	// previous file untouched), the daemon keeps running STALE config — make
	// that operator-visible instead of silent. status_detail reads
	// last_generate_result, so record a distinct marker (best-effort: the same
	// disk pressure that failed the main write may fail this too, but the
	// warn() always reaches syslog).
	let stale = false;
	try { stale = (fs.stat(CONFIG_OUT) != null); } catch (_) { stale = false; }
	if (stale) {
		warn("generate.uc: config write FAILED — CONTINUING ON PREVIOUS config (running stale)\n");
		try { log_mod.log_event("error", "config.write_failed_stale", {}); } catch (_) {}
		if (IS_PROD_OUT) try {
			fs.mkdir("/var/lib/singbox-ui", 0755);
			publish_atomic("/var/lib/singbox-ui/last_state.json",
				sprintf("{\"last_generate_ts\":%d,\"last_generate_result\":\"write_failed_stale\",\"config_hash\":\"unknown\"}", time()));
		} catch (_) {}
	} else {
		warn("generate.uc: config write FAILED and no usable config is present\n");
		try { log_mod.log_event("error", "config.write_failed", {}); } catch (_) {}
	}
	exit(1);
}

// C3.3 / S1.1 / S1.2: record GENERATE state for status_detail RPC, atomically
// (publish_atomic, same durability as the main config — no truncated read).
// This records only that a well-formed config was WRITTEN, NOT that sing-box
// accepted and is running it; hence `last_generate_result`. The real apply
// outcome is written by the init.d start path to apply_state.json
// (last_apply_result) after a successful `sing-box check`.
if (IS_PROD_OUT) try {
	fs.mkdir("/var/lib/singbox-ui", 0755);
	publish_atomic("/var/lib/singbox-ui/last_state.json",
		sprintf("{\"last_generate_ts\":%d,\"last_generate_result\":\"ok\",\"config_hash\":\"unknown\"}", time()));
} catch (_) {}

try { log_mod.log_event("info", "config.generated", {}); } catch (_) {}

print("OK\n");
