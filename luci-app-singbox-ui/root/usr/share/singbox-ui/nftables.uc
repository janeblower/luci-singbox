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

function log_err(msg) { warn(msg + "\n"); }

// uci_get_or_empty(cur, section, opt) — never throws, returns "".
// Mirrors subscription.uc; kept local to avoid cross-file imports.
function uci_get_or_empty(cur, section, opt) {
	let v = cur.get("singbox-ui", section, opt);
	return (v == null) ? "" : (type(v) === "array" ? (length(v) ? v[0] : "") : v);
}

// as_array(v) — normalises ucode value to an array.
// null/undefined → []; scalar → [v]; array → v.
function as_array(v) {
	if (v == null) return [];
	if (type(v) === "array") return v;
	return [v];
}

// fnv1a32(s) — 32-bit FNV-1a hash, hex-encoded (8 chars). Used to shorten
// long ruleset names; not a cryptographic primitive. Pure ucode so we don't
// require ucode-mod-digest, which isn't part of the default OpenWrt image.
function fnv1a32(s) {
	let h = 2166136261;
	let n = length(s);
	for (let i = 0; i < n; i++) {
		h = h ^ ord(s, i);
		h = (h * 16777619) & 0xffffffff;
	}
	return sprintf("%08x", h);
}

// set_name_for(name, idx, family) — nft set names are capped at 31 bytes.
// When the canonical `rs_${name}_${idx}_${family}` exceeds that, replace
// the user-provided name segment with an 8-hex-char FNV-1a hash. The hash
// is deterministic so set names stay stable across runs.
function set_name_for(name, idx, family) {
	let canon = `rs_${name}_${idx}_${family}`;
	if (length(canon) <= 31) return canon;
	return `rs_${fnv1a32(name)}_${idx}_${family}`;
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

		let idx = 0;
		for (let rule in doc.rules) {
			if (rule == null || rule.ip_cidr == null) { idx++; continue; }
			let v4 = [];
			let v6 = [];
			for (let c in as_array(rule.ip_cidr)) {
				let fam = classify_cidr(c);
				if (fam === "v4") push(v4, c);
				else if (fam === "v6") push(v6, c);
			}
			let network = rule.network ?? "";
			let ports = [];
			for (let p in as_array(rule.port_range)) {
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

function build_ruleset(port, v4, v6, iface) {
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
	if (v4 != null && v4 !== "")
		push(buf, `\t\tiifname "${iface}" ip  daddr { ${v4} } meta l4proto { tcp, udp } meta mark set 0x1\n`);
	if (v6 != null && v6 !== "")
		push(buf, `\t\tiifname "${iface}" ip6 daddr { ${v6} } meta l4proto { tcp, udp } meta mark set 0x1\n`);
	for (let r in rules) {
		let l4 = l4proto_expr(r.network);
		let pe = port_expr(r.network, r.ports);
		if (length(r.v4)) push(buf, emit_rs_rule(r.name, r.idx, "v4", l4, pe));
		if (length(r.v6)) push(buf, emit_rs_rule(r.name, r.idx, "v6", l4, pe));
	}
	push(buf, "\t}\n\n");

	push(buf, "\tchain prerouting_tproxy {\n");
	push(buf, "\t\ttype filter hook prerouting priority -149; policy accept;\n\n");
	push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip  to 127.0.0.1:${port}\n`);
	push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port}\n`);
	push(buf, "\t}\n");

	push(buf, "}\n");
	return join("", buf);
}

function cmd_emit(port, v4, v6, iface) {
	print(build_ruleset(port, v4, v6, iface));
}

// cmd_apply / cmd_remove come after build_ruleset because ucode does not
// hoist function declarations (unlike JavaScript) — forward references
// fail at call time with "left-hand side is not a function".
function cmd_remove() {
	system(["nft", "delete", "table", "inet", TABLE]);  // ignore rc; idempotent
}

function cmd_apply(cur) {
	let port  = uci_get_or_empty(cur, "tproxy", "port");
	if (port === "") port = "7893";
	let iface = uci_get_or_empty(cur, "tproxy", "interface");
	if (iface === "") iface = "br-lan";

	let v4 = uci_get_or_empty(cur, "fakeip", "inet4_range");
	let v6 = uci_get_or_empty(cur, "fakeip", "inet6_range");
	let rules = load_rs_rules();

	if (v4 === "" && v6 === "" && !length(rules)) {
		system(["nft", "delete", "table", "inet", TABLE]);  // ignore rc
		log_err("nftables: no fakeip ranges and no ruleset rules; table removed");
		return 0;
	}

	let ruleset = build_ruleset(port, v4, v6, iface);

	// Atomic replace handled inside the emitted ruleset (add+delete+table).
	// Write to a temp file and `nft -f path`. Avoids fs.popen write-mode
	// quirks across ucode versions.
	fs.mkdir(TMPDIR, 0o755);

	// Use mktemp so concurrent applies (cron + UI button) don't clobber
	// each other's scratch file mid-write.
	let proc = fs.popen(`mktemp -p ${TMPDIR} nftables.XXXXXX`, "r");
	if (!proc) {
		log_err("nftables: mktemp failed to spawn");
		return 1;
	}
	let tmp = trim(proc.read("all") || "");
	proc.close();
	if (length(tmp) === 0) {
		log_err("nftables: mktemp returned empty path");
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
case "emit":
	if (length(argv) !== 5) {
		log_err("Usage: nftables.uc emit PORT V4 V6 IFACE");
		exit(2);
	}
	cmd_emit(argv[1], argv[2], argv[3], argv[4]);
	break;
default:
	log_err("Usage: nftables.uc {apply|remove|emit PORT V4 V6 IFACE}");
	exit(2);
}
