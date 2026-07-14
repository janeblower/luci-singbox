// lib/inbound.uc — sing-box `inbounds` builder. Phase E2: descriptor-only
// dispatch; shared blocks own TLS / transport / multiplex.

// User-list entry formats split on the FIRST separator(s) only, so the
// trailing secret is preserved verbatim even when it contains ':':
//   mixed       "username:password"            (split once; password = tail)
//   hysteria2   "name:password"                (split once; password = tail)
//   shadowsocks "name:method:password"         (split twice; password = tail)
//   vless       "name:uuid[:flow]"             (UUIDs have no ':'; flow = tail)
// (C2.1.15 guard — colon-in-password no longer truncates; keep this note.)

let helpers = require("helpers");
let reg     = require("builder.protocols.registry");
let filler  = require("builder._filler");
let log_mod = require("log");

// Eagerly load every active inbound descriptor so register() fires. S2.1: each
// require() is wrapped so one malformed descriptor file logs+skips instead of
// throwing through require() and aborting generation for ALL protocols.
for (let _m in ["builder.protocols.trojan", "builder.protocols.shadowsocks", "builder.protocols.vless",
                "builder.protocols.hysteria2", "builder.protocols.hysteria", "builder.protocols.tuic",
                "builder.protocols.anytls", "builder.protocols.shadowtls", "builder.protocols.direct",
                "builder.protocols.tproxy", "builder.protocols.tun",
                "builder.protocols.redirect", "builder.protocols.mixed", "builder.protocols.json_raw",
                "builder.protocols.socks", "builder.protocols.http", "builder.protocols.vmess",
                "builder.protocols.naive", "builder.protocols.cloudflared"]) {
	try { require(_m); }
	catch (e) { warn(sprintf("inbound.uc: descriptor '%s' failed to load; skipping: %s\n", _m, e)); }
}

const s_opt = helpers.s_opt;

// Rule-set tags a tun inbound hands to sing-box for it to resolve itself.
const TUN_RS_KEYS = [ "route_address_set", "route_exclude_address_set" ];

// prune_dead_ruleset_refs(out, s, cur) — drop route_*_address_set entries whose
// rule-set is not active. The descriptor emits whatever UCI holds; it knows
// nothing about activity, and sing-box refuses the WHOLE config on a tag it
// cannot resolve ("parse route_address_set: rule-set not found: <tag>"), so
// disabling a rule-set must not be able to take the daemon down with it.
// helpers.ruleset_active is the ONE predicate for "is this rule-set live" (it
// honours the builtin master switch `main.default_rulesets`).
// Deletes the key entirely when nothing survives — an empty array is not the
// same as an absent one.
//
// This is NOT a harmless prune. tun.uc's own help text: "Only traffic matching
// these rule-sets' IP CIDRs enters the tunnel; everything else bypasses it." A
// route_address_set with nothing left in it means the tun captures the ENTIRE
// address space instead of "only these" — the mirror case
// (route_exclude_address_set) drags bypass traffic INTO the tunnel instead. Both
// directions are silent otherwise: warn() alone goes to stderr, and every
// production path (procd's start_service child, rpcd's `>/dev/null 2>&1`
// wrappers) throws stderr away — log_event popens `logger` itself and is the
// only channel the operator actually reads (mirrors generate.uc:70's
// transparent_conflict precedent).
function prune_dead_ruleset_refs(out, s, cur) {
	let rs_active = {};
	cur.foreach("singbox-ui", "ruleset", function(r) {
		rs_active[r[".name"]] = helpers.ruleset_active(cur, r);
	});
	for (let key in TUN_RS_KEYS) {
		if (out[key] == null) continue;
		let kept = [];
		for (let n in out[key]) {
			if (rs_active[n]) { push(kept, n); continue; }
			warn(sprintf("inbound.uc: tun '%s': rule-set '%s' is not active; dropping from %s\n",
			             s[".name"], n, key));
			try { log_mod.log_event("warn", "config.tun_ruleset_pruned",
			      { inbound: s[".name"], key: key, ruleset: n }); } catch (_) {}
		}
		if (length(kept)) out[key] = kept;
		else delete out[key];
	}
}

function build_one(s) {
	let proto = s_opt(s, "protocol");
	if (!proto) return null;
	let d = reg.get("inbound", proto);
	if (d == null) {
		warn(sprintf("inbound.uc: no descriptor for '%s'\n", proto));
		return null;
	}
	return (type(d.emit) === "function") ? d.emit(s) : filler.build(d, s);
}

function build_inbounds(cur) {
	let out = [];
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		let one = build_one(s);
		if (one == null) return;
		if (s_opt(s, "protocol") === "tun") prune_dead_ruleset_refs(one, s, cur);
		push(out, one);
	});
	return out;
}

// referenced_rulesets(inbounds) -> [tag, ...]
// The deduped rule-set tags the BUILT inbounds reference via a tun's
// route_address_set / route_exclude_address_set. generate.uc unions these into
// route.rule_set alongside route.uc's and dns.uc's sets: sing-box resolves these
// tags ITSELF, and a tag with no route.rule_set definition kills the whole config
// ("parse route_address_set: rule-set not found: <tag>", verified on 1.13.13).
// The tproxy path needs none of this — it reads rs_*.json behind sing-box's back.
//
// It takes the BUILT inbounds, not the cursor, ON PURPOSE. The condition under
// which tun.uc EMITS these keys (`requires: auto_route === "1"`, plus enabled,
// plus version gating, plus the prune above) must be the SAME condition under
// which we collect the names — the day the two disagree, we either emit a tag we
// never define (config dies) or define a rule-set nothing uses (background
// fetches for nothing). Reading the emitted objects makes them the same
// condition by construction instead of restating it here. Pure: no I/O.
function referenced_rulesets(inbounds) {
	let out = [];
	let seen = {};
	for (let one in inbounds ?? []) {
		if (one.type !== "tun") continue;
		for (let key in TUN_RS_KEYS) {
			// sing-box treats these fields as listable: a bare string ("route_address_set":
			// "ru_block") resolves as a tag exactly like a one-element array. Reachable
			// via the `json` protocol escape hatch (raw_json), which bypasses the
			// descriptor's `coerce: "array"`. `for (let n in <string>)` iterates zero
			// times in ucode, so without this the tag dangles uncollected.
			let refs = one[key] ?? [];
			if (type(refs) === "string") refs = [ refs ];
			for (let n in refs)
				if (!seen[n]) { push(out, n); seen[n] = true; }
		}
	}
	return out;
}

return { build_inbounds, build_one, referenced_rulesets };
