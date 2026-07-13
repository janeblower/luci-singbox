// lib/helpers.uc — shared helpers used by generate.uc, subscription.uc, nftables.uc.
// Everything here takes its inputs explicitly (a uci cursor, a path) — no globals.
// All of it is pure EXCEPT the two filesystem helpers at the bottom
// (unlink_quiet / is_stale), which the two refresh entry points share.

let fs = require("fs");

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

// detect_rs_format(target) — pick "binary" or "source" for a rule-set source
// path/URL purely from its file extension (.srs→binary, .json→source, else
// binary). There is no UI/UCI override: the `format` field was removed and the
// sing-box `format` key is always derived here. Shared between ruleset.uc and
// nft-rulesets.uc so both agree on the rule.
function detect_rs_format(target) {
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


// b64_decode(s) — tolerant base64 decoder for share-link / subscription
// payloads. Accepts the url-safe alphabet, missing padding, and embedded
// whitespace/newlines; returns the decoded string, or null on invalid input.
// The raw b64dec() builtin rejects all of those, so both the share-link parser
// (sharelink.uc) and the subscription body decode (subscription.uc) route
// through this single source so they can't drift.
function b64_decode(s) {
	if (s == null) return null;
	let t = replace(s, /\s+/g, "");
	t = replace(t, "-", "+");
	t = replace(t, "_", "/");
	let pad = length(t) % 4;
	if (pad === 2) t += "==";
	else if (pad === 3) t += "=";
	else if (pad === 1) return null;  // invalid base64 length
	let dec = null;
	try { dec = b64dec(t); } catch (e) { return null; }
	return dec;
}

// unlink_quiet(p) — best-effort unlink. Both entry points (subscription.uc and
// nft-rulesets.uc) call this inside per-job loops, where an unguarded throw would
// abort every REMAINING job in the refresh cycle: one bad subscription must not
// poison the rest.
function unlink_quiet(p) { try { fs.unlink(p); } catch (_) {} }

// is_stale(path, interval_s, force) -> bool. Missing file / zero interval / no
// interval => stale. Shared by the subscription and rule-set refresh paths, which
// each carried a byte-identical copy — staleness semantics drifting apart between
// the two cron jobs is exactly the kind of thing nobody notices.
function is_stale(path, interval_s, force) {
	if (force) return true;
	let st = fs.stat(path);
	if (!st) return true;
	if (interval_s == null || interval_s === 0) return true;
	return (time() - st.mtime) >= interval_s;
}

// builtin_rulesets_on(cur) — the `singbox-ui.main.default_rulesets` master
// switch. Unset means ON (NO-migration: an install that predates the option must
// not silently lose its rule-sets); only an explicit "0" turns them off.
function builtin_rulesets_on(cur) {
	return uci_get_or_empty(cur, "main", "default_rulesets") !== "0";
}

// ruleset_active(cur, s) — the ONE predicate for "is this rule-set live".
// Three call sites decide this (route.uc's rs_enabled map, dns.uc's
// ruleset_enabled_map, nft-rulesets.uc's fetch loop); each used to test
// `enabled !== "0"` on its own, so a builtin gate added to one would have left
// the other two fetching and referencing a rule-set the UI no longer shows.
function ruleset_active(cur, s) {
	if (s.enabled === "0") return false;
	if (s.builtin === "1" && !builtin_rulesets_on(cur)) return false;
	return true;
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
	fnv1a32,
	b64_decode,
	unlink_quiet,
	is_stale,
	builtin_rulesets_on,
	ruleset_active,
};
