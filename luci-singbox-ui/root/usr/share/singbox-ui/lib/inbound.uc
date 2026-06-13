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
                "builder.protocols.hysteria2", "builder.protocols.direct", "builder.protocols.tproxy",
                "builder.protocols.mixed", "builder.protocols.json_raw", "builder.protocols.socks",
                "builder.protocols.http", "builder.protocols.vmess"]) {
	try { require(_m); }
	catch (e) { warn(sprintf("inbound.uc: descriptor '%s' failed to load; skipping: %s\n", _m, e)); }
}

const s_opt = helpers.s_opt;

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
		if (one != null) push(out, one);
	});
	return out;
}

return { build_inbounds, build_one };
