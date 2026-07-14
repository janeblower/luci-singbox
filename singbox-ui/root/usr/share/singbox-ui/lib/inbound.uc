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
		}
		if (length(kept)) out[key] = kept;
		else delete out[key];
	}
}

// `cur` is optional: build_one(s) alone still works for the descriptor-level
// callers (tests, parity). It is threaded in from build_inbounds so a tun can
// drop references to rule-sets that are not active — filtering here rather than
// in the descriptor keeps the descriptor declarative and invertible.
function build_one(s, cur) {
	let proto = s_opt(s, "protocol");
	if (!proto) return null;
	let d = reg.get("inbound", proto);
	if (d == null) {
		warn(sprintf("inbound.uc: no descriptor for '%s'\n", proto));
		return null;
	}
	let out = (type(d.emit) === "function") ? d.emit(s) : filler.build(d, s);
	if (out != null && proto === "tun" && cur != null) prune_dead_ruleset_refs(out, s, cur);
	return out;
}

function build_inbounds(cur) {
	let out = [];
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		let one = build_one(s, cur);
		if (one != null) push(out, one);
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
		for (let key in TUN_RS_KEYS)
			for (let n in one[key] ?? [])
				if (!seen[n]) { push(out, n); seen[n] = true; }
	}
	return out;
}

return { build_inbounds, build_one, referenced_rulesets };
