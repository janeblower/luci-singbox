#!/usr/bin/ucode
// nftables.uc — emit/apply the singbox_ui nft ruleset.
//
// Subcommands (CLI contract identical to the prior nftables.sh):
//   apply                          — read UCI + rs_*.json, push ruleset to `nft -f -`
//   remove                         — delete the inet singbox_ui table
//   emit PORT V4 V6 IFACE [FWMARK FWMASK ROUTER_OUT]  — print the ruleset to stdout (used by tests)
//
// Single prerouting chain at priority mangle:
//   prerouting  (priority mangle)  per-flow ct mark decision + tproxy redirect

const TMPDIR = "/tmp/singbox-ui";
const TABLE  = "singbox_ui";

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");

function log_err(msg) { warn(msg + "\n"); }

// fnv1a32 — shared with lib/outbound.uc::safe_tag, exported from helpers.uc
// so there is exactly one implementation. See lib/helpers.uc for the body.
const fnv1a32 = helpers.fnv1a32;

// name_hash16(name) — 16-hex composite of two fnv1a32 digests over
// independent inputs (the raw name and a salted form). Cuts the
// pigeon-hole collision probability of the prior 8-hex form from
// ~2^-32 to ~2^-64 — a 4-billion-fold safety margin, eliminating
// realistic same-set-name collisions across renamed rulesets.
function name_hash16(name) {
	return fnv1a32(name) + fnv1a32(`g8|${name}`);
}

// set_name_for(name, idx, family) — nft set names are capped at 31 bytes.
// When the canonical `rs_${name}_${idx}_${family}` exceeds that, replace
// the user-provided name segment with a 16-hex-char composite FNV-1a
// hash. The hash is deterministic so set names stay stable across runs.
function set_name_for(name, idx, family) {
	let canon = `rs_${name}_${idx}_${family}`;
	if (length(canon) <= 31) return canon;
	return `rs_${name_hash16(name)}_${idx}_${family}`;
}

// read_json(path) — parse a JSON file. Returns null on missing file or parse
// failure. Used for rs_*.json caches that may be partial/corrupt.
function read_json(path) {
	let fd = fs.open(path, "r");
	if (!fd) return null;
	let raw = fd.read("all");
	fd.close();
	if (!raw || length(raw) === 0) return null;
	try { return json(raw); } catch (e) { return null; }
}

// classify_cidr(c) — "v4" / "v6" / null. Same heuristic as the bash version
// (presence of ':' marks v6). Empty strings are dropped by callers.
function classify_cidr(c) {
	if (c == null || c === "") return null;
	return index(c, ":") >= 0 ? "v6" : "v4";
}

// safe_cidr(family, v) — return v unchanged if it parses as a syntactically
// valid CIDR (or bare address) in the requested family, else null. Conservative
// regex: rejects ANY character that could escape the `{ … }` element body
// in the emitted nft script — braces, semicolons, hashes, backslashes,
// quotes, whitespace inside the literal. Centralised so both the fakeip
// path (UCI dns_server.inet[46]_range, see G1) and the rule-set path
// (rs_*.json ip_cidr entries, see G2) share one validator.
// valid_ipv6(a) — structural IPv6 validator (no prefix). S5.3: the old
// `[0-9A-Fa-f:]+` regex accepted nonsense like ":::" or a 9-group address,
// which then aborts the WHOLE atomic `nft -f` (one bad element fails the load).
// This rejects: triple colons, more than one "::", groups longer than 4 hex
// digits, and the wrong group count. Embedded-IPv4 forms (::ffff:1.2.3.4) are
// conservatively rejected — rare here, and dropping one is safer than letting
// an invalid literal abort the ruleset.
function valid_ipv6(a) {
	if (a == null || a === "") return false;
	if (!match(a, /^[0-9A-Fa-f:]+$/)) return false;
	if (index(a, ":::") >= 0) return false;          // three+ consecutive colons
	let has_dbl = index(a, "::") >= 0;
	if (has_dbl && index(substr(a, index(a, "::") + 2), "::") >= 0)
		return false;                                // more than one "::"
	let groups = split(a, ":");
	let nonempty = 0;
	for (let g in groups) {
		if (g === "") continue;
		if (!match(g, /^[0-9A-Fa-f]{1,4}$/)) return false;
		nonempty++;
	}
	if (has_dbl) return nonempty <= 7;               // "::" compresses 1+ groups
	return length(groups) === 8 && nonempty === 8;   // full form: exactly 8
}

function safe_cidr(family, v) {
	if (v == null) return null;
	let t = trim(`${v}`);
	if (t === "") return null;
	if (family === "v4") {
		let m = match(t, /^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})(\/([0-9]{1,2}))?$/);
		if (!m) return null;
		for (let i = 1; i <= 4; i++) if (+m[i] > 255) return null;   // octet range
		if (m[6] != null && +m[6] > 32) return null;                 // prefix range
		return t;
	}
	if (family === "v6") {
		let slash = index(t, "/");
		let addr = (slash < 0) ? t : substr(t, 0, slash);
		if (slash >= 0) {
			let pfx = substr(t, slash + 1);
			if (!match(pfx, /^[0-9]{1,3}$/) || +pfx > 128) return null;
		}
		return valid_ipv6(addr) ? t : null;
	}
	return null;
}

// safe_cidr_list(family, csv) — sanitise a comma-separated CIDR list from
// the UCI dns_server.inet[46]_range option. Each element is independently
// validated; anything that fails safe_cidr is dropped with a log_err. The
// returned string is interpolated verbatim into `daddr { … }`, so the
// rejoin uses ", " to preserve the existing test-asserted output shape.
function safe_cidr_list(family, csv) {
	if (csv == null) return "";
	let s = trim(`${csv}`);
	if (s === "") return "";
	let parts = split(s, ",");
	let out = [];
	for (let p in parts) {
		let safe = safe_cidr(family, p);
		if (safe) push(out, safe);
		else log_err(sprintf("nftables: dropping invalid %s CIDR %s", family, p));
	}
	return join(", ", out);
}

// safe_port_range(p) — sanitise ONE port_range token from rs_*.json. sing-box
// uses ':' for ranges; nft uses '-'. We normalise, then accept only a bare
// port or a port-port range whose every numeric part is in 1..65535 (same
// bound as validate_port). Returns the nft-safe token, or null (caller drops +
// log_err). The contract is BOTH injection-safe AND range-valid: a poisoned
// rs_*.json (MITM-able download) must not escape the `dport …` clause via a
// value like "80 }; insert rule …; #", and an out-of-range part like "99999"
// or "0" is dropped HERE rather than passing the regex and making the kernel
// reject the whole `nft -f` ruleset (a worse, all-or-nothing failure).
// Centralised so the only place ports reach the nft string is past this gate.
// NOTE: defined BEFORE load_rs_rules (its caller) — ucode resolves a forward
// reference to a later top-level function as a (nonexistent) global, so a
// callee MUST precede its caller in the file.
function safe_port_range(p) {
	if (p == null || p === "") return null;
	let tok = replace(`${p}`, ":", "-");
	if (!match(tok, /^[0-9]{1,5}(-[0-9]{1,5})?$/)) return null;
	let parts = split(tok, "-");
	for (let part in parts) {
		let n = +part;
		if (type(n) !== "int" || n < 1 || n > 65535) return null;
	}
	return tok;
}

// load_rs_rules() — scan /tmp/singbox-ui/rs_*.json and return a list of
// { name, idx, v4, v6, network, ports } entries (one per rule with ip_cidr).
// Each rule may produce a v4 entry, a v6 entry, both, or neither. Idx is the
// rule's position inside its file so set names stay stable across runs.
function load_rs_rules() {
	let out = [];
	let entries = fs.lsdir(TMPDIR);
	if (!entries) return out;

	// Stable order: sort filenames lexically so output is deterministic.
	let sorted = sort(entries);

	for (let fname in sorted) {
		if (substr(fname, 0, 3) !== "rs_") continue;
		if (substr(fname, -5) !== ".json") continue;
		let name = substr(fname, 3, length(fname) - 3 - 5);

		let doc = read_json(`${TMPDIR}/${fname}`);
		if (doc == null || type(doc.rules) !== "array") continue;

		// idx mirrors the rule's position in the source array, including
		// skipped (domain-only) entries — so set names stay stable when a
		// user adds/removes a domain rule earlier in the list.
		let idx = 0;
		for (let rule in doc.rules) {
			if (rule == null || rule.ip_cidr == null) { idx++; continue; }
			let v4 = [];
			let v6 = [];
			for (let c in helpers.as_array(rule.ip_cidr)) {
				let fam = classify_cidr(c);
				if (fam == null) continue;
				// G2: validate each CIDR before it lands in `elements = { … }`.
				// A poisoned rs_*.json (MITM-able download) could otherwise
				// inject arbitrary nft via `…/24 }; insert rule …; #`.
				let safe = safe_cidr(fam, c);
				if (safe == null) {
					log_err(sprintf("nftables: dropping invalid %s CIDR %s in rs_%s.json", fam, c, name));
					continue;
				}
				if (fam === "v4") push(v4, safe);
				else push(v6, safe);
			}
			let network = rule.network ?? "";
			let ports = [];
			for (let p in helpers.as_array(rule.port_range)) {
				// G2b/S1-1: validate each port_range token before it
				// lands in the `dport …` clause. A poisoned rs_*.json
				// could otherwise inject nft via "80 }; insert rule …; #".
				let tok = safe_port_range(p);
				if (tok == null) {
					if (p != null && p !== "")
						log_err(sprintf("nftables: dropping invalid port_range %s in rs_%s.json", p, name));
					continue;
				}
				push(ports, tok);
			}
			push(out, { name: name, idx: idx, v4: v4, v6: v6, network: network, ports: ports });
			idx++;
		}
	}
	return out;
}

// l4proto_expr(network) → "meta l4proto tcp" / "udp" / "{ tcp, udp }"
function l4proto_expr(network) {
	if (network === "tcp") return "meta l4proto tcp";
	if (network === "udp") return "meta l4proto udp";
	return "meta l4proto { tcp, udp }";
}

// port_expr(network, ports) → " tcp dport 80-443" etc. (leading space if non-empty).
// Multi-port specs become "{ p1, p2 }"; single ports stay bare.
function port_expr(network, ports) {
	if (!length(ports)) return "";
	let body;
	if (length(ports) === 1) body = ports[0];
	else body = `{ ${join(", ", ports)} }`;
	let kw;
	if (network === "tcp") kw = "tcp";
	else if (network === "udp") kw = "udp";
	else kw = "th";
	return ` ${kw} dport ${body}`;
}

// emit_named_set(name, type_, body, with_interval) — write a named set
// declaration. Used by wan_ifaces, fakeip4, fakeip6, rs_* paths and emit_set.
function emit_named_set(name, type_, body, with_interval) {
	let lines = [`\tset ${name} {\n`, `\t\ttype ${type_}\n`];
	if (with_interval) push(lines, "\t\tflags interval\n");
	push(lines, `\t\telements = { ${body} }\n`, "\t}\n\n");
	return join("", lines);
}

// emit_set(set_name, family, cidrs) → nft set definition for a cidr set.
// Thin wrapper over emit_named_set (flags interval always on for cidr sets);
// both call sites pass literal "v4"/"v6", so the family→type ternary is exact.
// MUST be defined AFTER emit_named_set: ucode compiles a reference to a
// top-level function declared later as a (missing) global, so the callee must
// precede the caller in the file.
function emit_set(set_name, family, cidrs) {
	return emit_named_set(set_name, (family === "v6") ? "ipv6_addr" : "ipv4_addr",
	                      join(", ", cidrs), true);
}

// emit_rs_decision(name, idx, family, l4, port_e, mark) — single
// `ct state new …` decision rule that ORs $MARK into ct mark for a
// per-flow decision. Replaces the old emit_rs_rule (which wrote
// per-packet meta mark — the original bug we are fixing).
// Rule ordering: ip-kw daddr @set l4 port ct state new ct mark set …
// mirrors the old emit_rs_rule shape so set-lookup comes before
// conntrack state check (cheaper on average: most packets are not
// destined to a proxied address).
function emit_rs_decision(name, idx, family, l4, port_e, mark) {
	let set_name = set_name_for(name, idx, family);
	let ip_kw = (family === "v6") ? "ip6" : "ip";
	return sprintf(
		"\t\t%s daddr @%s %s%s ct state new ct mark set ct mark or 0x%x\n",
		ip_kw, set_name, l4, port_e, mark);
}

// emit_rs_decision_block(rules, mark, fakeip4_cidr, fakeip6_cidr) — write the
// fakeip v4/v6 decisions plus one rule per rs_* set. Pulled out so
// both the prerouting and output chains emit the same block.
// fakeip4_cidr / fakeip6_cidr are the validated CIDR strings (empty string
// means "not configured" — skip that family's decision rule entirely so we
// never emit 'ip6 daddr @fakeip6' when the user left fakeip_range_v6 blank).
function emit_rs_decision_block(rules, mark, fakeip4_cidr, fakeip6_cidr) {
	let buf = [];
	if (length(fakeip4_cidr)) {
		push(buf, sprintf(
			"\t\tct state new iifname @wan_ifaces ip  daddr @fakeip4 meta l4proto { tcp, udp } ct mark set ct mark or 0x%x\n",
			mark));
	}
	if (length(fakeip6_cidr)) {
		push(buf, sprintf(
			"\t\tct state new iifname @wan_ifaces ip6 daddr @fakeip6 meta l4proto { tcp, udp } ct mark set ct mark or 0x%x\n",
			mark));
	}
	for (let r in rules) {
		let l4 = l4proto_expr(r.network);
		let pe = port_expr(r.network, r.ports);
		if (length(r.v4)) push(buf, emit_rs_decision(r.name, r.idx, "v4", l4, pe, mark));
		if (length(r.v6)) push(buf, emit_rs_decision(r.name, r.idx, "v6", l4, pe, mark));
	}
	return join("", buf);
}

// safe_iface(name) — return name unchanged if it matches the conservative
// nft-safe character class, else null. The shell-allowed netdev charset is
// actually wider (kernel only enforces no '/' or NUL and a 15-byte cap), but
// real-world OpenWrt interfaces never use anything beyond [A-Za-z0-9_.@-]:
// "br-lan", "eth0", "eth0.100", "br-lan@if5", "pppoe-wan", "wg_home". Any
// character outside this set in a UCI option is overwhelmingly a typo or an
// injection attempt — both must be rejected before being baked into the
// `iifname "..."` string literal, which has no escape sequences.
function safe_iface(name) {
	if (name == null || name === "") return null;
	return match(name, /^[A-Za-z0-9_.@\-]+$/) ? name : null;
}

// filter_ifaces(ifaces) — drop entries that fail safe_iface() with a warning.
// Centralised so both cmd_apply (UCI source) and cmd_emit (CLI argv source)
// share the same guarantee before the list reaches the nft string.
function filter_ifaces(ifaces) {
	let out = [];
	for (let n in ifaces) {
		let s = safe_iface(n);
		if (s != null) push(out, s);
		else log_err(sprintf("nftables: invalid iface name %s, skipped", n));
	}
	return out;
}

// safe_fwmark(v, fallback) — accept hex ("0x1") or decimal ("1"), return
// the parsed uint32 in range [1, 0xffffffff], else fallback. Centralised
// here so cmd_emit (CLI argv source) and cmd_apply (UCI source) share
// one validator, symmetric with safe_iface / safe_cidr / validate_port.
function safe_fwmark(v, fallback) {
	if (v == null) return fallback;
	let t = trim(`${v}`);
	if (t === "") return fallback;
	if (!match(t, /^(0x[0-9a-fA-F]{1,8}|[0-9]+)$/)) return fallback;
	let n = (substr(t, 0, 2) === "0x") ? +`0x${substr(t, 2)}` : +t;
	if (type(n) !== "int" || n < 1 || n > 0xffffffff) return fallback;
	return n;
}

// fwmark_pair(mark, mask) — enforce the invariant (mark & mask) == mark;
// log and fall back to the default 0x40000000/0x40000000 if violated. Returns
// a list [mark, mask] of validated values.
function fwmark_pair(mark_raw, mask_raw) {
	let mark = safe_fwmark(mark_raw, 0x40000000);
	let mask = safe_fwmark(mask_raw, 0x40000000);
	if ((mark & mask) !== mark) {
		log_err(sprintf("nftables: fwmark 0x%x outside fwmark_mask 0x%x; falling back to 0x40000000", mark, mask));
		return [0x40000000, 0x40000000];
	}
	return [mark, mask];
}

// validate_port(p) — return integer in 1..65535 or null. Accepts strings
// ("7893"), bare ints (7893), and rejects "", null, "abc", "99999", "0",
// negative numbers. Callers must treat null as "skip tproxy emission".
// Mirrors lib/outbound.uc::safe_port so both code paths agree on the rule.
function validate_port(p) {
	if (p == null || p === "") return null;
	let n = (type(p) === "int") ? p : +p;
	if (type(n) !== "int" || n < 1 || n > 65535) return null;
	return n;
}

// emit_named_sets(buf, ifaces, v4, v6, rules) — wan_ifaces + fakeip4/6 + one
// set per rs_* rule×family. Pulled out of build_ruleset (S1-QUAL): pure string
// assembly, no behaviour change. v4/v6 are the already-sanitised CIDR strings
// (null → empty body). fakeip4/fakeip6 are always emitted (empty body OK).
function emit_named_sets(buf, ifaces, v4, v6, rules) {
	let iface_body = "";
	if (length(ifaces)) {
		let quoted = [];
		for (let i in ifaces) push(quoted, sprintf('"%s"', i));
		iface_body = join(", ", quoted);
	}
	push(buf, emit_named_set("wan_ifaces", "ifname", iface_body, false));

	// fakeip4 / fakeip6 always emitted (empty body OK if no UCI value).
	push(buf, emit_named_set("fakeip4", "ipv4_addr", v4 != null ? v4 : "", true));
	push(buf, emit_named_set("fakeip6", "ipv6_addr", v6 != null ? v6 : "", true));

	// rs_*_v4 / rs_*_v6 (one set per rule × family, unchanged from before).
	for (let r in rules) {
		if (length(r.v4)) push(buf, emit_set(set_name_for(r.name, r.idx, "v4"), "v4", r.v4));
		if (length(r.v6)) push(buf, emit_set(set_name_for(r.name, r.idx, "v6"), "v6", r.v6));
	}
}

// emit_prerouting_chain(buf, rules, mark, mask, v4, v6, port_n) — the
// prerouting chain: socket-transparent fast-path, ct-mark restore, NEW-flow
// decisions, mark propagate, and the tproxy block (only when port_n != null).
// Verbatim move of the inline block from build_ruleset (S1-QUAL).
function emit_prerouting_chain(buf, rules, mark, mask, v4, v6, port_n) {
	push(buf, "\tchain prerouting {\n");
	push(buf, "\t\ttype filter hook prerouting priority mangle; policy accept;\n\n");

	// (1) Fast-path: established TCP/UDP already handled by an
	// IP_TRANSPARENT socket inside sing-box.
	push(buf, sprintf(
		"\t\tmeta l4proto tcp socket transparent 1 meta mark set 0x%x accept\n",
		mark & mask));

	// (2) Restore decision from conntrack for established / related.
	push(buf, "\t\tmeta mark set ct mark\n");

	// (3) NEW-flow decisions: OR our bit into ct mark.
	// Pass v4/v6 so fakeip4/fakeip6 decision rules are only emitted when
	// the respective CIDR is configured (empty string → skip that family).
	push(buf, emit_rs_decision_block(rules, mark, v4, v6));

	// (4) Propagate freshly-set ct mark into the packet mark.
	push(buf, "\t\tmeta mark set ct mark\n");

	// (5) TPROXY when the bit is set, using AND-mask (not exact eq).
	// Pad the family keyword to 3 chars (ip → "ip ") so ip and ip6 rules
	// align visually, and the test assertion 'tproxy ip  to' holds (the
	// extra space comes from the format + the space before 'to').
	if (port_n != null) {
		for (let family in ["ip", "ip6"]) {
			for (let proto in ["tcp", "udp"]) {
				let target = (family === "ip") ? sprintf("127.0.0.1:%d", port_n) : sprintf("[::1]:%d", port_n);
				let fam_padded = (family === "ip") ? "ip " : "ip6";
				push(buf, sprintf(
					"\t\tmeta mark and 0x%x == 0x%x meta l4proto %s tproxy %s to %s\n",
					mask, mark, proto, fam_padded, target));
			}
		}
	}
	push(buf, "\t}\n");
}

// emit_output_chain(buf, rules, mark, v4, v6) — optional router-traffic
// redirect chain. Verbatim move of the inline block from build_ruleset
// (S1-QUAL); only emitted when router_out is set.
function emit_output_chain(buf, rules, mark, v4, v6) {
	push(buf, "\n\tchain output {\n");
	push(buf, "\t\ttype route hook output priority mangle; policy accept;\n\n");
	push(buf, "\t\tmeta mark set ct mark\n");
	push(buf, emit_rs_decision_block(rules, mark, v4, v6));
	push(buf, "\t\tmeta mark set ct mark\n");
	push(buf, "\t}\n");
}

function build_ruleset(port, v4, v6, ifaces, mark, mask, router_out, rules) {
	// Defensive defaults so old callers (e.g., legacy tests) keep working.
	if (mark == null) mark = 0x40000000;
	if (mask == null) mask = 0x40000000;
	if (router_out == null) router_out = 0;

	ifaces = filter_ifaces(ifaces);
	v4 = safe_cidr_list("v4", v4);
	v6 = safe_cidr_list("v6", v6);

	let port_n = validate_port(port);
	if (port_n == null) {
		log_err(sprintf("nftables: invalid listen_port %s (need int 1..65535), skipping tproxy chain", port));
	}

	// S1-PERF: the apply path already loaded the rs_*.json cache and passes
	// it in here, so we don't re-scan + re-parse every rule-set file a second
	// time per apply. Non-apply callers (emit) pass nothing → load once.
	if (rules == null) rules = load_rs_rules();

	let buf = [];
	// Atomic transaction: add + delete + table all in one nft -f.
	push(buf, "add table inet singbox_ui\n");
	push(buf, "delete table inet singbox_ui\n");
	push(buf, "table inet singbox_ui {\n");

	emit_named_sets(buf, ifaces, v4, v6, rules);
	emit_prerouting_chain(buf, rules, mark, mask, v4, v6, port_n);
	if (router_out) emit_output_chain(buf, rules, mark, v4, v6);

	push(buf, "}\n");
	return join("", buf);
}

function cmd_emit(port, v4, v6, iface_str, mark_raw, mask_raw, routerout_raw) {
	let ifaces = (iface_str && length(iface_str)) ? split(iface_str, ",") : [];
	let mp = fwmark_pair(mark_raw, mask_raw);
	let mark = mp[0]; let mask = mp[1];
	let router_out = (routerout_raw === "1" || routerout_raw === 1) ? 1 : 0;
	print(build_ruleset(port, v4, v6, ifaces, mark, mask, router_out));
}

// cmd_apply / cmd_remove come after build_ruleset because ucode does not
// hoist function declarations (unlike JavaScript) — forward references
// fail at call time with "left-hand side is not a function".
// nft_delete_table_quiet() — drops the table if present.
//
// Uses argv form to match the file-wide convention (see system(["nft", "-f", tmp])
// in cmd_apply) and avoid passing TABLE through /bin/sh re-parsing. The argv
// form bypasses shell so the "2>/dev/null" suppression trick the old string
// form used is no longer available: on first install nft will print
// "Error: Could not process rule: No such file or directory" to stderr.
// That message is benign (the whole point of this call is "best-effort
// delete"), and procd / rpcd handlers already ignore stderr from helper
// commands. Trading a single line of harmless noise for shell-injection
// safety is the right call.
function nft_delete_table_quiet() {
	system(["nft", "delete", "table", "inet", TABLE]);
}

function cmd_remove() { nft_delete_table_quiet(); }

// first_nft_tproxy(cur) — first enabled inbound with protocol=tproxy and
// nft_rules not explicitly "0". Returns the section object or null.
function first_nft_tproxy(cur) {
	let found = null;
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (found) return;
		if (s.enabled === "0") return;
		if (s.protocol !== "tproxy") return;
		if (s.nft_rules === "0") return;
		found = s;
	});
	return found;
}

// count_nft_tproxy(cur) — number of enabled inbounds qualifying for the
// nft tproxy chain. Used by cmd_apply to warn when the user has more
// than one such inbound: the nft chain points at `first_nft_tproxy`'s
// port only, so any extras silently lose TPROXY traffic even though
// sing-box itself binds their listen_port.
function count_nft_tproxy(cur) {
	let n = 0;
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		if (s.protocol !== "tproxy") return;
		if (s.nft_rules === "0") return;
		n++;
	});
	return n;
}

// any_nft_transparent(cur) — true if a tproxy or tun inbound requests nft rules.
function any_nft_transparent(cur) {
	let yes = false;
	cur.foreach("singbox-ui", "inbound", function(s) {
		if (s.enabled === "0") return;
		if (s.protocol === "tproxy" && s.nft_rules !== "0") yes = true;
		if (s.protocol === "tun"    && s.nft_rules === "1") yes = true;
	});
	return yes;
}

// first_fakeip(cur) — ranges of the first enabled dns_server with type=fakeip.
// A fakeip server with nft_rules="0" opts out of nft redirect: it contributes
// no ranges, so no fakeip4/fakeip6 decision rule is emitted. Unset (default)
// keeps the historical "always redirect fakeip" behaviour.
function first_fakeip(cur) {
	let r = { v4: "", v6: "" };
	let found = false;
	cur.foreach("singbox-ui", "dns_server", function(s) {
		if (found) return;
		if (s.enabled === "0") return;
		if (s.type !== "fakeip") return;
		found = true;
		if (s.nft_rules === "0") return;
		r.v4 = s.inet4_range ?? "";
		r.v6 = s.inet6_range ?? "";
	});
	return r;
}

// rand_hex(n) — n random bytes from /dev/urandom, hex-encoded. Returns
// null when /dev/urandom is unavailable (containers/test envs without
// the device). Pure file I/O, no shell.
function rand_hex(n) {
	let fd = fs.open("/dev/urandom", "r");
	if (!fd) return null;
	let raw = fd.read(n);
	fd.close();
	if (!raw || length(raw) === 0) return null;
	let h = "";
	for (let i = 0; i < length(raw); i++) h += sprintf("%02x", ord(raw, i));
	return h;
}

// APPLY_LOCK — serialization point for cmd_apply. ucode's fs has no flock, and
// fs.open(path, "x") is NOT an exclusive-create primitive here ("x" is not a
// valid base open mode in ucode → open returns null WITHOUT creating the file,
// so it can never serialize). We instead use a lock *directory*: mkdir(2) is
// atomic and fails with EEXIST for the second caller. Two concurrent applies
// (cron refresh racing a manual Apply) would otherwise interleave their
// `nft -f` calls and hit the TOCTOU window in make_nft_tmp's fallback.
const APPLY_LOCK = `${TMPDIR}/.apply.lock`;
const APPLY_LOCK_OWNER = `${APPLY_LOCK}/owner`;
// Per-process owner token, set when THIS process holds the lock. Used by
// release to avoid removing a lock another apply reclaimed after our TTL.
let _lock_token = null;

// _get_lock_owner() — read the persisted owner token (or null). Defined BEFORE
// _set_lock_owner because the latter re-reads via this to verify the write, and
// ucode has no function hoisting — a callee must precede its caller.
function _get_lock_owner() {
	let f = fs.open(APPLY_LOCK_OWNER, "r");
	if (!f) return null;
	let v = f.read("all"); f.close();
	return v;
}
// _set_lock_owner(token) — write the owner token, then re-read and compare to
// confirm it actually persisted. S5/SEC-3: the prior version ignored both the
// fs.open failure and the f.write result, so a crash/ENOSPC between mkdir and a
// completed owner write left the lock dir with an empty/absent owner — the
// winner could then fail to release its OWN lock (release compares the token,
// which no longer matches), wedging apply until the 60s TTL. Returns true only
// when the token is verifiably on disk.
function _set_lock_owner(token) {
	let f = fs.open(APPLY_LOCK_OWNER, "w");
	if (!f) return false;
	let ok = true;
	try { f.write(token); } catch (_) { ok = false; }
	f.close();
	if (!ok) return false;
	return _get_lock_owner() === token;
}

// acquire_apply_lock() — atomic create-or-fail via fs.mkdir. mkdir is the
// portable lock primitive: it returns falsy on EEXIST without throwing (proven
// by make_nft_tmp/subscription.uc calling it on an existing dir every run).
// Returns true on success, false if another apply holds the lock. A lock dir
// older than 60s is treated as stale (a crashed apply) and reclaimed, so we
// never wedge permanently. The winner stamps a unique owner token so release
// only ever removes its own lock.
function acquire_apply_lock() {
	fs.mkdir(TMPDIR, 0o755);
	let token = rand_hex(8) ?? sprintf("%d-%d", time(), 0);
	if (fs.mkdir(APPLY_LOCK, 0o755)) {
		// SEC-3: confirm the owner token persisted. If the write failed
		// (ENOSPC/crash window), we hold a lock we could never release by
		// token — so drop it and report failure rather than wedge apply for
		// the 60s TTL. The caller logs + the next apply retries cleanly.
		if (!_set_lock_owner(token)) {
			fs.rmdir(APPLY_LOCK);
			return false;
		}
		_lock_token = token;
		return true;
	}
	// Lock dir exists — reclaim if stale (a crashed apply). S5.1: a plain
	// rmdir+mkdir reclaim is a TOCTOU race — two applies both observe "stale",
	// both rmdir+mkdir, and both believe they won. Reclaim ATOMICALLY via
	// rename instead: of N concurrent reclaimers, only one can rename the stale
	// dir away (the rest get ENOENT — the source is already gone), so exactly
	// one proceeds to recreate the lock.
	//
	// SEC-3: a lock dir is reclaimable EITHER (a) older than the 60s TTL, OR
	// (b) it has no owner token AND is past a short grace period. A healthy
	// holder writes (and now verifies) its owner microseconds after mkdir, so
	// an owner-less dir older than the grace can only be a crash mid-acquire —
	// reclaiming it ~58s sooner than the TTL avoids wedging on that crash.
	// The grace is essential: WITHOUT it a concurrent acquirer that mkdir-loses
	// the race could read the winner's lock in the instant BEFORE the winner's
	// owner write lands, see "no owner", and steal the fresh lock — turning two
	// concurrent applies into two winners. mtime resolution is 1s, so an owner
	// write always completes well within the grace window; the grace never fires
	// on a live holder, only on a stuck one.
	const LOCK_NOOWNER_GRACE = 5;
	let st = fs.stat(APPLY_LOCK);
	let owner = _get_lock_owner();
	let no_owner = (owner == null) || (trim(`${owner}`) === "");
	let aged = (st != null) && ((time() - st.mtime) > 60);
	let stuck_no_owner = (st != null) && no_owner && ((time() - st.mtime) >= LOCK_NOOWNER_GRACE);
	if (aged || stuck_no_owner) {
		let moved = `${APPLY_LOCK}.stale.${rand_hex(6) ?? sprintf("%d", time())}`;
		if (fs.rename(APPLY_LOCK, moved)) {
			try { fs.unlink(`${moved}/owner`); } catch (_) {}
			fs.rmdir(moved);
			if (fs.mkdir(APPLY_LOCK, 0o755)) {
				if (!_set_lock_owner(token)) {
					fs.rmdir(APPLY_LOCK);
					return false;
				}
				_lock_token = token;
				return true;
			}
		}
	}
	return false;
}

// release_apply_lock() — S5.2: only release a lock we still own. If our apply
// outran the 60s stale TTL (e.g. a wedged nft -f) and another apply reclaimed
// the lock, the owner token no longer matches ours — leave that lock intact
// rather than stealing it out from under the new holder.
function release_apply_lock() {
	if (_lock_token != null && _get_lock_owner() === _lock_token) {
		try { fs.unlink(APPLY_LOCK_OWNER); } catch (_) {}
		fs.rmdir(APPLY_LOCK);
	}
	_lock_token = null;
}

// make_nft_tmp() — compose a unique tmp path inside TMPDIR without
// invoking mktemp via fs.popen. fs.popen() in OpenWrt's ucode does not
// accept argv-form (probed; returns null), so the only way to drop
// the shell from this path is to generate the name ourselves. Prefers
// /dev/urandom for collision resistance; falls back to time()+slot
// when the device is missing (test envs).
function make_nft_tmp() {
	fs.mkdir(TMPDIR, 0o755);
	let suffix = rand_hex(6);
	if (suffix != null) return `${TMPDIR}/nftables.${suffix}`;
	let base = time();
	for (let i = 0; i < 64; i++) {
		let p = sprintf("%s/nftables.%d.%d", TMPDIR, base, i);
		if (fs.stat(p) == null) return p;
	}
	return null;
}

// ip_rule_smoke_check(mark, mask) — best-effort, log-only check that
// the host has an `ip rule` entry whose fwmark matches what we baked
// into the ruleset. Missing rule → warning in syslog (silent
// blackhole otherwise). Never fails or retries — the `ip rule` setup
// is the operator's job. We just surface a misconfiguration.
function ip_rule_smoke_check(mark, mask) {
	let want = (mask == 0xffffffff)
		? sprintf("0x%x", mark)
		: sprintf("0x%x/0x%x", mark, mask);
	let proc = fs.popen("ip -4 rule show; ip -6 rule show");
	if (!proc) return;
	let raw = proc.read("all");
	proc.close();
	if (raw != null && index(raw, want) >= 0) return;
	log_err(sprintf(
		"nftables: warning: no ip rule with fwmark %s found; tproxy traffic may not reach listen_port",
		want));
}

// gather_apply_params(cur) — collect everything _cmd_apply_locked needs from
// UCI into one struct, so the decision logic (which tproxy owns the rules,
// which mark, which fakeip ranges) is unit-testable on the host via the
// `params` CLI without running `nft -f`. Per-inbound fwmark wins over the
// global; the global stays the back-compat fallback (and is what the
// operator's `ip rule` is keyed on). When the mark comes from the inbound,
// mask is derived = mark so (mark & mask) == mark always holds.
function gather_apply_params(cur) {
	let tp = first_nft_tproxy(cur);

	let port = (tp && tp.listen_port != null && tp.listen_port !== "") ? tp.listen_port : "7893";
	let ifaces = tp ? helpers.as_array(tp.interface) : [];
	if (!length(ifaces)) ifaces = [ "br-lan" ];

	let fip = first_fakeip(cur);

	let glob = null;
	cur.foreach("singbox-ui", "global", function(s) { if (!glob) glob = s; });

	let mark_raw, mask_raw;
	if (tp && tp.fwmark != null && tp.fwmark !== "") {
		mark_raw = tp.fwmark;
		mask_raw = tp.fwmark;
	} else {
		mark_raw = glob ? glob.fwmark      : null;
		mask_raw = glob ? glob.fwmark_mask : null;
	}
	let mp = fwmark_pair(mark_raw, mask_raw);
	let routerout_raw = glob ? glob.redirect_router_traffic : null;

	return {
		transparent:  any_nft_transparent(cur) ? 1 : 0,
		tproxy_count: count_nft_tproxy(cur),
		port: port,
		ifaces: ifaces,
		v4: fip.v4, v6: fip.v6,
		mark: mp[0], mask: mp[1],
		router_out: (routerout_raw === "1" || routerout_raw === 1) ? 1 : 0,
	};
}

// _cmd_apply_locked(cur) — the real apply body. Every return path here
// (S1-2 invalid-port guard, table-removed, tmp-alloc/open failure, nft -f
// failure, success) is reached *inside* the lock held by the cmd_apply
// wrapper below; the wrapper releases the lock on whichever rc this returns,
// so no early return can leak the lock. Defined before cmd_apply because
// ucode does not hoist function declarations.
function _cmd_apply_locked(cur) {
	let p = gather_apply_params(cur);

	// Transparent gate: when no tproxy/tun inbound owns nft rules there is no
	// table to build — drop any stale table and return success. This is what
	// makes the fakeip and rule-set nft checkboxes no-ops when tproxy nft is
	// off: their sets only ever live inside this table.
	if (!p.transparent) {
		nft_delete_table_quiet();
		return 0;
	}

	// More than one tproxy inbound requests the chain: it points at the first
	// one's port only, so any extras silently lose TPROXY traffic.
	if (p.tproxy_count > 1) {
		log_err(sprintf("nftables: %d enabled tproxy inbounds with nft_rules set; using only the first — multiple enabled tproxy inbounds are unsupported", p.tproxy_count));
	}

	// S1-2: an invalid tproxy listen_port would make build_ruleset skip the
	// tproxy block while still emitting marking rules — a silent blackhole.
	// Surface it as an apply failure instead of a 0 exit that looks like success.
	if (validate_port(p.port) == null) {
		log_err(sprintf("nftables: invalid tproxy listen_port %s (need int 1..65535); refusing to apply a marking-only ruleset", p.port));
		return 1;
	}

	let rules = load_rs_rules();

	if (p.v4 === "" && p.v6 === "" && !length(rules)) {
		nft_delete_table_quiet();
		log_err("nftables: no fakeip ranges and no ruleset rules; table removed");
		return 0;
	}

	let ruleset = build_ruleset(p.port, p.v4, p.v6, p.ifaces, p.mark, p.mask, p.router_out, rules);

	// G6: tmp file path composed on the ucode side — no shell, no mktemp.
	let tmp = make_nft_tmp();
	if (tmp == null) {
		log_err("nftables: could not allocate a tmp file path");
		return 1;
	}

	let fd = fs.open(tmp, "w");
	if (!fd) {
		log_err(`nftables: cannot open ${tmp}`);
		fs.unlink(tmp);
		return 1;
	}
	fd.write(ruleset);
	fd.close();
	// S5.4: bound nft -f with `timeout` so a wedged apply (e.g. nft blocked on a
	// busy ruleset) can't hold the apply lock for its full 60s stale TTL. 30s is
	// comfortably above a normal atomic load and well under the TTL. busybox and
	// coreutils both return 124 on timeout.
	//
	// `timeout` is NOT present on a stock OpenWrt though — it is not a busybox
	// applet and coreutils-timeout is not a dependency — so system(["timeout",..])
	// would return 127 and make EVERY firewall apply fail on a default box. Probe
	// for it once and fall back to a plain `nft -f` when absent; the timeout bound
	// is a best-effort safety net, not a correctness requirement.
	let timed = false;
	let tproc = fs.popen("command -v timeout 2>/dev/null");
	if (tproc) {
		let tout = tproc.read("all");
		tproc.close();
		timed = (tout != null && length(trim(tout)) > 0);
	}
	let rc = timed ? system(["timeout", "30", "nft", "-f", tmp])
	               : system(["nft", "-f", tmp]);
	fs.unlink(tmp);
	if (rc !== 0) {
		log_err((timed && rc == 124) ? "nftables: nft -f timed out (30s)" : "nftables: nft -f failed");
		return 1;
	}
	// Best-effort smoke check: warn (don't fail) when the host has no
	// `ip rule` matching the fwmark/mask we baked into the ruleset.
	ip_rule_smoke_check(p.mark, p.mask);
	return 0;
}

// cmd_apply(cur) — thin lock wrapper around _cmd_apply_locked. Acquiring the
// O_EXCL lock here (and releasing it on whatever rc the inner body returns)
// guarantees the lock is freed on *every* path — including the early-return
// guards (S1-2 invalid port, nft -f failure) and the success path — before
// the dispatcher's `exit(cmd_apply(cur))` ends the process. A second
// concurrent apply that fails to acquire returns 1 (logged) instead of
// racing.
function cmd_apply(cur) {
	if (!acquire_apply_lock()) {
		log_err("nftables: another apply is in progress (lock held); skipping");
		return 1;
	}
	let rc = _cmd_apply_locked(cur);
	release_apply_lock();
	return rc;
}

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();

let argv = ARGV;
switch (argv[0]) {
// cmd_apply returns 0 on success and 1 on every failure path (invalid
// tproxy port, tmp-file alloc/open failure, `nft -f` non-zero). Propagate
// that as the process exit code: ucode CLI only exits non-zero via an
// explicit exit(), so a bare `cmd_apply(cur); break;` would discard the
// return and always exit 0 — hiding both the S1-2 guard and real `nft -f`
// failures from init.d (`_nft_rc=$?`) and rpcd. exit() ends the process,
// so no `break` is needed (and the ip_rule smoke check already ran inside).
case "apply":  exit(cmd_apply(cur));
// remove stays a query-style success: cmd_remove() -> nft_delete_table_quiet()
// returns null (no explicit return), so it must NOT be passed to exit().
// Its "best-effort delete" contract is always-success, so falling through
// to the normal exit 0 below is correct.
case "remove": cmd_remove();   break;
case "needed":
	print(any_nft_transparent(cur) ? "1\n" : "0\n");
	break;
// `params` — read-only debug/test seam: print gathered apply parameters as
// JSON (mark/mask in hex) without running `nft -f`. Used by host tests to
// drive UCI fixtures through gather_apply_params(). Not wired to rpcd/ACL.
case "params": {
	let p = gather_apply_params(cur);
	printf("{\"transparent\":%d,\"tproxy_count\":%d,\"port\":\"%s\",\"v4\":\"%s\",\"v6\":\"%s\",\"mark\":\"0x%x\",\"mask\":\"0x%x\",\"router_out\":%d}\n",
		p.transparent, p.tproxy_count, p.port, p.v4, p.v6, p.mark, p.mask, p.router_out);
	break;
}
case "emit":
	// PORT V4 V6 IFACE [FWMARK FWMASK ROUTER_OUT]
	if (length(argv) < 5 || length(argv) > 8) {
		log_err("Usage: nftables.uc emit PORT V4 V6 IFACE [FWMARK FWMASK ROUTER_OUT]");
		exit(2);
	}
	cmd_emit(argv[1], argv[2], argv[3], argv[4],
		length(argv) > 5 ? argv[5] : null,
		length(argv) > 6 ? argv[6] : null,
		length(argv) > 7 ? argv[7] : null);
	break;
default:
	log_err("Usage: nftables.uc {apply|remove|needed|params|emit PORT V4 V6 IFACE [FWMARK FWMASK ROUTER_OUT]}");
	exit(2);
}
