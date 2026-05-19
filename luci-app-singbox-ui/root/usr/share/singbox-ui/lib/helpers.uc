// lib/helpers.uc — shared helpers used by generate.uc, subscription.uc, nftables.uc.
// All functions are pure (no I/O) and take a uci cursor explicitly.

// uci_get_or_empty(cur, section, opt) — never throws, returns "" on missing.
// Array form (list option) collapses to the first element.
function uci_get_or_empty(cur, section, opt) {
	let v = cur.get("singbox-ui", section, opt);
	return (v == null) ? "" : (type(v) === "array" ? (length(v) ? v[0] : "") : v);
}

// get_bool(cur, section, opt) — UCI "1" → true, else false.
function get_bool(cur, section, opt) {
	return cur.get("singbox-ui", section, opt) === "1";
}

// get_list(cur, section, opt) — list option as ucode array.
// Scalar values become a one-element array; null/missing → [].
// NOTE: differs from generate.uc's pre-refactor local get_list which returned
// scalars unwrapped. When migrating callers, update any `for (... in get_list(...))`
// usage to expect always-array semantics.
function get_list(cur, section, opt) {
	let all = cur.get_all("singbox-ui", section);
	if (all == null) return [];
	let v = all[opt];
	if (v == null) return [];
	return (type(v) === "array") ? v : [ v ];
}

// sections_where(cur, opt, value) — list of section names where opt == value.
function sections_where(cur, opt, value) {
	let out = [];
	cur.foreach("singbox-ui", null, function (s) {
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

// sq(s) — single-quote escape for /bin/sh.
function sq(s) { return "'" + replace(s, "'", "'\\''") + "'"; }

return {
	uci_get_or_empty,
	get_bool,
	get_list,
	sections_where,
	as_array,
	sq,
};
