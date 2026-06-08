// lib/inbound.uc — sing-box `inbounds` builder. Phase E2: descriptor-only
// dispatch; shared blocks own TLS / transport / multiplex.

// Shadowsocks inbound ss_user format limitation: each entry is "name:password"
// with `:` as the FIRST-colon separator. A password containing a literal colon
// is truncated at the second colon — operators must base64-encode it or pick a
// colon-free passphrase. Mirrored in docs/uci-schema.md → inbound shadowsocks
// section. (C2.1.15 guard — keep this comment even after full descriptor migration.)

let helpers = require("helpers");
let reg     = require("protocols.registry");

// Eagerly load every active inbound descriptor so register() fires.
require("protocols.trojan");
require("protocols.shadowsocks");
require("protocols.vless");
require("protocols.hysteria2");
require("protocols.direct");
require("protocols.tproxy");
require("protocols.mixed");

const s_opt    = helpers.s_opt;
const s_bool   = helpers.s_bool;
const s_num    = helpers.s_num;
const csv_list = helpers.csv_list;
const as_array = helpers.as_array;

// build_user(s) — single-user object for vless/trojan/hysteria2.
// Used by inbound descriptors that expose server_uuid / server_password
// fields for single-user configuration.
function build_user(s) {
	let proto = s.protocol;
	let u = { name: s[".name"] };
	if (proto === "vless" || proto === "vmess") {
		if (length(s_opt(s, "server_uuid"))) u.uuid = s.server_uuid;
	}
	if (proto === "trojan" || proto === "hysteria2") {
		if (length(s_opt(s, "server_password"))) u.password = s.server_password;
	}
	if (proto === "vless" && length(s_opt(s, "vless_flow")) && s.vless_flow !== "none")
		u.flow = s.vless_flow;
	return u;
}

// build_inbound_users(s, proto) — parse `list inbound_user` entries for
// vless (multi-user). Returns an array of user objects, or [] when no valid
// entries.  Format per entry:
//   vless: "name:uuid"          or "name:uuid:flow"
// Invalid entries (missing name/uuid) are silently skipped.
function build_inbound_users(s, proto) {
	let entries = as_array(s.inbound_user);
	let out = [];
	for (let entry in entries) {
		let parts = split(entry, ":");
		if (length(parts) < 2) continue;
		let name = parts[0], uuid = parts[1];
		if (!length(name) || !length(uuid)) continue;
		let u = { name: name, uuid: uuid };
		if (length(parts) >= 3 && length(parts[2])) {
			if (proto === "vless") {
				if (parts[2] !== "none") u.flow = parts[2];
			}
		}
		push(out, u);
	}
	return out;
}

function build_one(s) {
	let proto = s_opt(s, "protocol");
	if (!proto) return null;
	let d = reg.get("inbound", proto);
	if (d == null) {
		warn(sprintf("inbound.uc: no descriptor for '%s'\n", proto));
		return null;
	}
	return d.emit(s);
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

return { build_inbounds, build_one, build_user, build_inbound_users };
