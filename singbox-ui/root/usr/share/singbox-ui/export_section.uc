#!/usr/bin/ucode
// export_section.uc — emit the sing-box JSON for ONE UCI section.
// Invoked by the rpcd handler as:
//   ucode -L /usr/share/singbox-ui/lib export_section.uc <kind> <name>
// where kind is inbound | outbound | dns_server | dns_rule | route_rule | ruleset.
// Always prints exactly one JSON line:
//   {"status":"ok","section":<obj>}     on success
//   {"status":"error","message":"…"}    on any failure (unknown kind, missing
//                                       section, refused outbound type, etc.)
//
// This script never writes files, never restarts services, never touches
// nftables — it is a pure read of the UCI state plus a call into the shared
// builders (lib/section_json.uc, which the JSON editor's import path also uses,
// so export and import can't drift apart).
//
// Env overrides (tests):
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

'use strict';

function emit(obj) { printf("%J\n", obj); }
function fail(msg) { emit({ status: "error", message: msg }); exit(0); }

let kind = ARGV[0] || "";
let name = ARGV[1] || "";

if (!length(name)) fail("missing name");

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur;
try {
	cur = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
} catch (e) { fail("uci cursor failed"); }

let sj;
try { sj = require("section_json"); } catch (e) { fail("require(section_json) failed"); }

let res = sj.export_one(cur, kind, name);
emit(res);
