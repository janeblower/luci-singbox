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
				if (fam === "v4") push(v4, c);
				else if (fam === "v6") push(v6, c);
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

function build_ruleset(port, v4, v6, ifaces) {
	// ifaces is an array of interface names.
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
	push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip  to 127.0.0.1:${port}\n`);
	push(buf, `\t\tmeta mark 0x1 meta l4proto { tcp, udp } tproxy ip6 to [::1]:${port}\n`);
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
// nft_delete_table_quiet() — drops the table if present; redirects stderr to
// /dev/null so the "No such file or directory" noise from a missing table
// doesn't reach procd logs / rpcd JSON output.
function nft_delete_table_quiet() {
	system(`nft delete table inet ${TABLE} 2>/dev/null`);
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

function cmd_apply(cur) {
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
