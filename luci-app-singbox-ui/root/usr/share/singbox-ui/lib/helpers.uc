// lib/helpers.uc — shared helpers used by generate.uc, subscription.uc, nftables.uc.
// All functions are pure (no I/O) and take a uci cursor explicitly.

// uci_get_or_empty(cur, section, opt) — never throws, returns "" on missing.
// Array form (list option) collapses to the first element. Cursor-based
// (foreach-dict callers should use s_opt() on the section object instead).
function uci_get_or_empty(cur, section, opt) {
	let v = cur.get("singbox-ui", section, opt);
	return (v == null) ? "" : (type(v) === "array" ? (length(v) ? v[0] : "") : v);
}

// Section-dict helpers — operate on the object returned by cur.foreach() /
// cur.get_all(). Centralized so inbound/outbound/dns builders don't copy them.
function s_opt(s, k)  { let v = s[k]; return (v == null) ? "" : v; }
function s_bool(s, k) { return s[k] === "1"; }
function s_num(v)     { let n = +v; return n || 0; }

// csv_list("a, b ,c") -> ["a","b","c"]; "" / null -> [].
function csv_list(v) {
	if (v == null || v === "") return [];
	let out = [];
	for (let p in split(v, ",")) { let t = trim(p); if (length(t)) push(out, t); }
	return out;
}

// sections_of_kind(cur, kind, opt, value) — list section names of a given
// UCI `.type` whose `opt` equals `value`. Filtering by kind is important
// because option names (e.g. `type`, `nft_rules`) recur across unrelated
// section kinds; an unfiltered walk would silently match those too.
function sections_of_kind(cur, kind, opt, value) {
	let out = [];
	cur.foreach("singbox-ui", kind, function (s) {
		if (s[opt] === value) push(out, s[".name"]);
	});
	return out;
}

// as_array(v) — null → []; scalar → [v]; array → v.
function as_array(v) {
	if (v == null) return [];
	if (type(v) === "array") return v;
	return [v];
}

// detect_rs_format(target, override) — pick "binary" or "source" for a
// rule-set source path/URL. Explicit override wins; otherwise extension.
// Shared between ruleset.uc and subscription.uc so both agree on the rule.
function detect_rs_format(target, override) {
	if (override === "binary" || override === "source") return override;
	let lower = lc(target || "");
	if (substr(lower, -4) === ".srs")  return "binary";
	if (substr(lower, -5) === ".json") return "source";
	return "binary";
}

// sq(s) — single-quote escape for /bin/sh.
function sq(s) { return "'" + replace(s, "'", "'\\''") + "'"; }

// resolve_iface_device(iface) — translate a UCI logical interface name
// (e.g. "wan", "lan") into the actual Linux netdev (e.g. "eth0", "pppoe-wan").
// Falls back to the input verbatim when resolution fails or the daemon is
// reached outside an OpenWrt environment (tests, dev containers); the latter
// behaviour is what lets a user type a real device name directly.
//
// Test override: env SINGBOX_DEV_<iface> (non-alphanumeric → '_').
function resolve_iface_device(iface) {
	if (iface == null || iface === "") return iface;
	let key = "SINGBOX_DEV_" + replace(iface, /[^A-Za-z0-9_]/g, "_");
	let v = getenv(key);
	if (v != null && length(v)) return v;
	let fs_mod = require("fs");
	let p = fs_mod.popen(
		". /lib/functions/network.sh 2>/dev/null; " +
		"network_get_device DEV " + sq(iface) + " 2>/dev/null && printf %s \"$DEV\"",
		"r");
	if (!p) return iface;
	let body = trim(p.read("all") ?? "");
	p.close();
	return length(body) ? body : iface;
}

return {
	uci_get_or_empty,
	s_opt,
	s_bool,
	s_num,
	csv_list,
	sections_of_kind,
	as_array,
	sq,
	detect_rs_format,
	resolve_iface_device,
};
