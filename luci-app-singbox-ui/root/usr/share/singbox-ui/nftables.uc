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
