#!/usr/bin/ucode
// import_section.uc — turn a hand-edited sing-box JSON object back into the UCI
// fields of ONE section. Invoked by the rpcd handler as:
//   ucode -L /usr/share/singbox-ui/lib import_section.uc <kind> <name>
// with the JSON object on STDIN. Always prints exactly one JSON line:
//   {"status":"ok","tag":…,"fields":{…},"known":[…],"extra":{…}}
//   {"status":"error","message":"…"}
//
// PURE READ — the counterpart of export_section.uc, through the same
// lib/section_json.uc. It writes NOTHING: it parses the JSON against the
// section's descriptor and hands the caller back what to write. The frontend
// applies that into LuCI's own uci changeset, so Save & Apply / Revert behave
// exactly as they do for a hand-edited form, and this method sits on the READ
// ACL.
//
//   fields — the UCI options the JSON carried.
//   known  — every UCI option this descriptor COULD produce. The caller removes
//            the ones absent from `fields`; anything NOT in `known` is a UCI-only
//            option (enabled, builtin, nft_rules, sub_*) and must be left alone.
//   extra  — json keys the descriptor does not model. The caller shows them to
//            the user, and on confirmation stores them in `json_extra`, which the
//            filler merges back at build time. Nothing is dropped silently.
//   tag    — the section name from the JSON. A changed tag is a RENAME of this
//            section, never a new one.
//
// Reading the body from stdin (not argv) keeps a config with passwords in it out
// of the process table.
//
// Env overrides (tests):
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

'use strict';

function emit(obj) { printf("%J\n", obj); }
function fail(msg) { emit({ status: "error", message: msg }); exit(0); }

let kind = ARGV[0] || "";
let name = ARGV[1] || "";

if (!length(name)) fail("missing name");

let body = require("fs").stdin.read("all") ?? "";
if (!length(trim(body))) fail("empty body");

let obj;
try { obj = json(body); } catch (e) { fail("invalid JSON: " + e); }
if (obj == null) fail("invalid JSON");

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur;
try {
	cur = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
} catch (e) { fail("uci cursor failed"); }

let sj;
try { sj = require("section_json"); } catch (e) { fail("require(section_json) failed"); }

emit(sj.import_one(cur, kind, name, obj));
