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
	// Strip query string (and fragment) before suffix matching so URLs like
	// https://x/path/file.srs?ver=1 are still recognized as binary instead
	// of falling through to the default. Without this, the suffix check sees
	// "...srs?ver=1" and never matches ".srs".
	let q = index(lower, "?");
	if (q >= 0) lower = substr(lower, 0, q);
	let h = index(lower, "#");
	if (h >= 0) lower = substr(lower, 0, h);
	if (substr(lower, -4) === ".srs")  return "binary";
	if (substr(lower, -5) === ".json") return "source";
	return "binary";
}

// sq(s) — single-quote escape for /bin/sh.
function sq(s) { return "'" + replace(s, "'", "'\\''") + "'"; }

// fnv1a32(s) — 32-bit FNV-1a hash, hex-encoded (8 chars). Used to shorten
// long names to a stable identifier; not a cryptographic primitive. Pure
// ucode so we don't require ucode-mod-digest, which isn't part of the
// default OpenWrt image. Shared between nftables.uc (rs_*_<hash>_<fam>
// set names) and lib/outbound.uc (safe_tag fallback for hostile
// share-link names).
function fnv1a32(s) {
	let h = 2166136261;
	let n = length(s);
	for (let i = 0; i < n; i++) {
		h = h ^ ord(s, i);
		h = (h * 16777619) & 0xffffffff;
	}
	return sprintf("%08x", h);
}

// resolve_iface_device(iface) — translate a UCI logical interface name
// (e.g. "wan", "lan") into the actual Linux netdev (e.g. "eth0", "pppoe-wan").
// Falls back to the input verbatim when resolution fails or the daemon is
// reached outside an OpenWrt environment (tests, dev containers); the latter
// behaviour is what lets a user type a real device name directly.
//
// Test override: env SINGBOX_DEV_<iface> (non-alphanumeric → '_').
//
// Caching: each lookup forks `. /lib/functions/network.sh` via popen, which
// is non-trivial on a slow router (ash + sourcing network.sh ≈ 30–80 ms).
// Outbound builders may call this N times per generate run (once per
// `bind_interface`). Memoise at module scope so the second call onward is
// O(1). The cache lives for the lifetime of the ucode process — rpcd
// daemonises so generate.uc imports happen per-invocation and the cache is
// implicitly fresh; long-lived hosts call reset_iface_cache() at the top
// of generate.uc to avoid stale netdev mappings across config reloads.
let _iface_dev_cache = {};

function resolve_iface_device(iface) {
	if (iface == null || iface === "") return iface;
	if (_iface_dev_cache[iface] !== undefined) return _iface_dev_cache[iface];
	let key = "SINGBOX_DEV_" + replace(iface, /[^A-Za-z0-9_]/g, "_");
	let v = getenv(key);
	if (v != null && length(v)) { _iface_dev_cache[iface] = v; return v; }
	let fs_mod = require("fs");
	let p = fs_mod.popen(
		". /lib/functions/network.sh 2>/dev/null; " +
		"network_get_device DEV " + sq(iface) + " 2>/dev/null && printf %s \"$DEV\"",
		"r");
	if (!p) { _iface_dev_cache[iface] = iface; return iface; }
	let body = trim(p.read("all") ?? "");
	p.close();
	let result = length(body) ? body : iface;
	_iface_dev_cache[iface] = result;
	return result;
}

// reset_iface_cache() — clear the module-scope memoisation table. Called
// from generate.uc on entry so a config reload always re-resolves netdevs;
// also useful for tests that flip the SINGBOX_DEV_<iface> env between cases.
function reset_iface_cache() { _iface_dev_cache = {}; }

// OUTBOUND_PROXY_KINDS — the set of outbound `type` values that are real
// proxy protocols (as opposed to interface / url / subscription / direct /
// block / dns / selector / urltest). Single source for membership checks
// across export_section.uc and lib/outbound.uc::build_outbounds() dispatch
// branches — when a new protocol is added, only this list (and the
// build_constructor_for switch) needs touching.
//
// Note: a *different*, shorter list exists at outbound.uc:144 covering
// only user-credential proxies (vless/vmess/trojan) for transport+multiplex
// emission. That subset is semantically distinct and is NOT merged here.
const OUTBOUND_PROXY_KINDS = [
	"vless", "vmess", "trojan", "hysteria2", "shadowsocks", "tuic", "anytls",
];

function is_outbound_proxy_kind(t) {
	for (let k in OUTBOUND_PROXY_KINDS) if (k === t) return true;
	return false;
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
	reset_iface_cache,
	fnv1a32,
	OUTBOUND_PROXY_KINDS,
	is_outbound_proxy_kind,
};
