// lib/protocols/json_raw.uc — raw passthrough outbound/inbound types (Task 4).
//
// Two user-facing "types" that store their input verbatim in UCI and expand it
// into the sing-box config at generate time, instead of the frontend parsing it
// into structured fields (which is lossy and can't represent every protocol):
//
//   type=json      raw_json  — a literal sing-box outbound/inbound JSON object,
//                              spliced in verbatim. Covers ANY protocol
//                              (vmess/tuic/anytls/…) with no per-protocol code.
//   type=sharelink raw_link  — a share-link URL (vless/ss/trojan/hysteria2/
//                              vmess), parsed by lib/sharelink.uc at generate.
//
// In both cases the UCI section name is the authoritative tag, overriding any
// tag embedded in the raw input — route rules / dns.detour reference the
// section name, so the emitted object must carry it.

let reg = require("protocols.registry");

// emit_json(s) — parse the raw JSON object and stamp the section tag.
function emit_json(s) {
	let raw = s.raw_json;
	if (type(raw) !== "string" || !length(trim(raw))) return null;
	let obj;
	try { obj = json(raw); }
	catch (e) {
		warn(sprintf("json_raw: '%s' has invalid JSON: %s\n", s[".name"], e));
		return null;
	}
	if (type(obj) !== "object") {
		warn(sprintf("json_raw: '%s' raw_json is not a JSON object\n", s[".name"]));
		return null;
	}
	obj.tag = s[".name"];
	return obj;
}

// emit_sharelink(s) — expand a share-link URL into an outbound object.
function emit_sharelink(s) {
	let raw = s.raw_link;
	if (type(raw) !== "string" || !length(trim(raw))) return null;
	let obj = require("sharelink").parse_proxy_url(trim(raw));
	if (type(obj) !== "object") {
		warn(sprintf("json_raw: '%s' raw_link could not be parsed as a share-link\n", s[".name"]));
		return null;
	}
	obj.tag = s[".name"];
	return obj;
}

reg.register({
	kind: "outbound", type: "json", sing_box_type: "",
	fields: [
		{ name: "raw_json", type: "string", tab: "basic", required: true, multiline: true,
		  ui_label: "Raw JSON (sing-box outbound object)",
		  placeholder: "{\"type\":\"vmess\",\"server\":\"…\",\"server_port\":443,\"uuid\":\"…\"}" },
	],
	emit: emit_json,
});

reg.register({
	kind: "inbound", type: "json", sing_box_type: "",
	fields: [
		{ name: "raw_json", type: "string", tab: "basic", required: true, multiline: true,
		  ui_label: "Raw JSON (sing-box inbound object)",
		  placeholder: "{\"type\":\"mixed\",\"listen\":\"::\",\"listen_port\":2080}" },
	],
	emit: emit_json,
});

reg.register({
	kind: "outbound", type: "sharelink", sing_box_type: "",
	fields: [
		{ name: "raw_link", type: "string", tab: "basic", required: true, multiline: true,
		  ui_label: "Share-link URL",
		  placeholder: "vless://uuid@host:443?security=tls&sni=example.com#name" },
	],
	emit: emit_sharelink,
});

return {};
