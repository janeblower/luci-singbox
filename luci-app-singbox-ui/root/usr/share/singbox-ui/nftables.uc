#!/usr/bin/ucode
// nftables.uc — emit/apply the singbox_ui nft ruleset.
//
// Subcommands (CLI contract identical to the prior nftables.sh):
//   apply                          — read UCI + rs_*.json, push ruleset to `nft -f -`
//   remove                         — delete the inet singbox_ui table
//   emit PORT V4 V6 IFACE          — print the ruleset to stdout (used by tests)
//
// Two prerouting chains:
//   prerouting_mark   (priority -150)  marks matching connections (fakeip + rs_*)
//   prerouting_tproxy (priority -149)  tproxy-redirects marked connections

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
function safe_cidr(family, v) {
	if (v == null) return null;
	let t = trim(`${v}`);
	if (t === "") return null;
	if (family === "v4")
		return match(t, /^[0-9]{1,3}(\.[0-9]{1,3}){3}(\/[0-9]{1,2})?$/) ? t : null;
	if (family === "v6")
		return match(t, /^[0-9A-Fa-f:]+(\/[0-9]{1,3})?$/) ? t : null;
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
				if (p == null || p === "") continue;
				// nft uses '-' for ranges; sing-box uses ':'.
				push(ports, replace(`${p}`, ":", "-"));
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

// emit_set(set_name, family, cidrs) → string with the nft set definition.
function emit_set(set_name, family, cidrs) {
	let typ = (family === "v6") ? "ipv6_addr" : "ipv4_addr";
	let body = join(",", cidrs);
	let lines = [
		`\tset ${set_name} {\n`,
		`\t\ttype ${typ}\n`,
		`\t\tflags interval\n`,
		`\t\telements = { ${body} }\n`,
		`\t}\n\n`,
	];
	return join("", lines);
}

// emit_rs_rule(name, idx, family, l4, port_e) — single marking rule line.
function emit_rs_rule(name, idx, family, l4, port_e) {
	let set_name = set_name_for(name, idx, family);
	let ip_kw = (family === "v6") ? "ip6" : "ip";
	return `\t\t${ip_kw} daddr @${set_name} ${l4}${port_e} ct state new meta mark set 0x1\n`;
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

function build_ruleset(port, v4, v6, ifaces) {
	// ifaces is an array of interface names. Filter once at the entrypoint
	// so neither iface_expr below nor any future caller can leak an
	// unsanitised name into the nft string.
	ifaces = filter_ifaces(ifaces);

	// G1: sanitise fakeip CIDR ranges before they are interpolated into
	// `daddr { … }`. Source is `dns_server.inet[46]_range` which the LuCI
	// UI marks as cidr4/cidr6 but UCI bypasses client-side validation.
	// Apply here so both cmd_apply (UCI source) and cmd_emit (CLI argv
	// source) share one guarantee — mirrors the safe_iface convention.
	v4 = safe_cidr_list("v4", v4);
	v6 = safe_cidr_list("v6", v6);

	// Validate listen_port: emitting `tproxy ... :abc` or `:99999` produces
	// an nft script that fails to load on apply. We'd rather skip the
	// tproxy chain (and log) than poison the whole ruleset transaction.
	let port_n = validate_port(port);
	if (port_n == null) {
		log_err(sprintf("nftables: invalid listen_port %s (need int 1..65535), skipping tproxy chain", port));
	}

	let iface_expr;
	if (length(ifaces) === 0)      iface_expr = null;
	else if (length(ifaces) === 1) iface_expr = sprintf('iifname "%s"', ifaces[0]);
	else {
		let quoted = [];
		for (let i in ifaces) push(quoted, sprintf('"%s"', i));
		iface_expr = sprintf('iifname { %s }', join(", ", quoted));
	}

	let rules = load_rs_rules();

	let buf = [];
	// Atomic transaction: `add` is idempotent (creates the table if missing),
	// `delete` then removes it within the same nft -f transaction, and the
	// trailing `table {...}` re-creates it. nft applies all three atomically.
	push(buf, "add table inet singbox_ui\n");
	push(buf, "delete table inet singbox_ui\n");
	push(buf, "table inet singbox_ui {\n");

	for (let r in rules) {
		if (length(r.v4)) push(buf, emit_set(set_name_for(r.name, r.idx, "v4"), "v4", r.v4));
		if (length(r.v6)) push(buf, emit_set(set_name_for(r.name, r.idx, "v6"), "v6", r.v6));
	}

	push(buf, "\tchain prerouting_mark {\n");
	push(buf, "\t\ttype filter hook prerouting priority -150; policy accept;\n\n");
	if (v4 != null && v4 !== "" && iface_expr != null)
		push(buf, `\t\t${iface_expr} ip  daddr { ${v4} } meta l4proto { tcp, udp } meta mark set 0x1\n`);
	if (v6 != null && v6 !== "" && iface_expr != null)
		push(buf, `\t\t${iface_expr} ip6 daddr { ${v6} } meta l4proto { tcp, udp } meta mark set 0x1\n`);
	for (let r in rules) {
		let l4 = l4proto_expr(r.network);
		let pe = port_expr(r.network, r.ports);
		if (length(r.v4)) push(buf, emit_rs_rule(r.name, r.idx, "v4", l4, pe));
		if (length(r.v6)) push(buf, emit_rs_rule(r.name, r.idx, "v6", l4, pe));
	}
	push(buf, "\t}\n\n");

	push(buf, "\tchain prerouting_tproxy {\n");
	push(buf, "\t\ttype filter hook prerouting priority -149; policy accept;\n\n");
	// Only emit tproxy rules when the port validated. An empty chain still
	// hooks prerouting but performs no action — safer than syntactically
	// broken `tproxy ... :<garbage>` that aborts the whole nft transaction.
	if (port_n != null) {
		push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip  to 127.0.0.1:${port_n}\n`);
		push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port_n}\n`);
	}
	push(buf, "\t}\n");

	push(buf, "}\n");
	return join("", buf);
}

function cmd_emit(port, v4, v6, iface_str) {
	let ifaces = (iface_str && length(iface_str)) ? split(iface_str, ",") : [];
	print(build_ruleset(port, v4, v6, ifaces));
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
function first_fakeip(cur) {
	let r = { v4: "", v6: "" };
	let found = false;
	cur.foreach("singbox-ui", "dns_server", function(s) {
		if (found) return;
		if (s.enabled === "0") return;
		if (s.type !== "fakeip") return;
		found = true;
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

function cmd_apply(cur) {
	// G3: warn if more than one enabled tproxy inbound asks for nft
	// rules — only the first contributes to the tproxy chain, any
	// extras silently lose TPROXY traffic. We don't drop the extras
	// (sing-box still binds their ports); the warning surfaces the
	// inconsistency to the operator.
	let n_tp = count_nft_tproxy(cur);
	if (n_tp > 1) {
		log_err(sprintf("nftables: %d enabled tproxy inbounds with nft_rules set; using only the first — multiple enabled tproxy inbounds are unsupported", n_tp));
	}

	let tp = first_nft_tproxy(cur);
	let port = (tp && tp.listen_port != null && tp.listen_port !== "") ? tp.listen_port : "7893";
	let ifaces = tp ? helpers.as_array(tp.interface) : [];
	if (!length(ifaces)) ifaces = [ "br-lan" ];

	let fip = first_fakeip(cur);
	let v4 = fip.v4;
	let v6 = fip.v6;
	let rules = load_rs_rules();

	if (v4 === "" && v6 === "" && !length(rules)) {
		nft_delete_table_quiet();
		log_err("nftables: no fakeip ranges and no ruleset rules; table removed");
		return 0;
	}

	let ruleset = build_ruleset(port, v4, v6, ifaces);

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
	let rc = system(["nft", "-f", tmp]);
	fs.unlink(tmp);
	if (rc !== 0) {
		log_err("nftables: nft -f failed");
		return 1;
	}
	return 0;
}

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();

let argv = ARGV;
switch (argv[0]) {
case "apply":  cmd_apply(cur); break;
case "remove": cmd_remove();   break;
case "needed":
	print(any_nft_transparent(cur) ? "1\n" : "0\n");
	break;
case "emit":
	if (length(argv) !== 5) {
		log_err("Usage: nftables.uc emit PORT V4 V6 IFACE");
		exit(2);
	}
	cmd_emit(argv[1], argv[2], argv[3], argv[4]);
	break;
default:
	log_err("Usage: nftables.uc {apply|remove|needed|emit PORT V4 V6 IFACE}");
	exit(2);
}
