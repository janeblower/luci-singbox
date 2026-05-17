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

function cmd_apply(cur)             { /* TODO Task 4 */ }
function cmd_remove()               { /* TODO Task 4 */ }
function cmd_emit(port, v4, v6, if_) { /* TODO Task 3 */ }

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
