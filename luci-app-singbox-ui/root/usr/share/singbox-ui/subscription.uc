#!/usr/bin/ucode
// Unified subscription/ruleset fetcher and refresh driver.
// Subcommands:
//   fetch-subs                              — download all subscription outbounds
//   fetch-rulesets                          — download all nft_rules=1 rule-sets
//   refresh [subscriptions|rulesets|all] [force]
//
// Env overrides (used by tests):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)
//   SINGBOX        (default /usr/bin/sing-box)
//   UCI_CONFIG_DIR (honoured by require("uci").cursor)
//   SINGBOX_NO_RELOAD=1 — refresh skips the init.d reload (tests)

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
const SINGBOX    = getenv("SINGBOX")        || "/usr/bin/sing-box";
const DEFAULT_UA = "Mozilla/5.0";

let fs  = require("fs");
let uci_mod = require("uci");

function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn(msg + "\n"); }

function cmd_fetch_subs(cur)               { /* TODO Task 2 */ }
function cmd_fetch_rulesets(cur)           { /* TODO Task 3 */ }
function cmd_refresh(cur, what, force)     { /* TODO Task 4 */ }

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
fs.mkdir(TMPDIR, 0o755);

let argv = ARGV;
let sub = argv[0] || "";
switch (sub) {
case "fetch-subs":     cmd_fetch_subs(cur); break;
case "fetch-rulesets": cmd_fetch_rulesets(cur); break;
case "refresh":        cmd_refresh(cur, argv[1] || "all", argv[2] === "force"); break;
default:
	log_err("usage: subscription.uc {fetch-subs|fetch-rulesets|refresh [what] [force]}");
	exit(2);
}
