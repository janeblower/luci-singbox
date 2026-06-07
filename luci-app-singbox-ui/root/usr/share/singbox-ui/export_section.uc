#!/usr/bin/ucode
// export_section.uc — emit the sing-box JSON for ONE inbound or outbound UCI
// section. Invoked by the rpcd handler as:
//   ucode -L /usr/share/singbox-ui/lib export_section.uc <kind> <name>
// where kind is "inbound" | "outbound".  Always prints exactly one JSON line:
//   {"status":"ok","section":<obj>}     on success
//   {"status":"error","message":"…"}    on any failure (unknown kind, missing
//                                       section, refused outbound type, etc.)
//
// This script never writes files, never restarts services, never touches
// nftables — it is a pure read of the UCI state plus a call into the shared
// builders. The handler simply forwards our stdout to rpcd.
//
// Env overrides (tests):
//   UCI_CONFIG_DIR — honoured by require("uci").cursor

'use strict';

function emit(obj) { printf("%J\n", obj); }
function fail(msg) { emit({ status: "error", message: msg }); exit(0); }

// Apply lib/scrub.uc on the section object before emit so that read-ACL users
// never see uuid/password/private_key/etc. verbatim (spec C1.2). Loaded lazily
// to keep the bad-kind / missing-name error paths independent of scrub.uc.
function scrubbed(obj) {
	let scrub = require("scrub");
	return scrub.scrub_secrets(obj);
}

let kind = ARGV[0] || "";
let name = ARGV[1] || "";

if (kind !== "inbound" && kind !== "outbound") fail("invalid kind");
if (!length(name))                              fail("missing name");

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur;
try {
	cur = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
} catch (e) { fail("uci cursor failed"); }

let section = cur.get_all("singbox-ui", name);
if (!section)                       fail("section not found");
if (section[".type"] !== kind)      fail("section is not " + kind);

if (kind === "inbound") {
	let mod;
	try { mod = require("inbound"); } catch (e) { fail("require(inbound) failed"); }
	let ob = mod.build_one(section);
	if (!ob) fail("build_one returned null");
	emit({ status: "ok", section: scrubbed(ob) });
} else {
	let t = section.type;
	// build_constructor_for() only handles the proxy-protocol kinds. The
	// UI-only shapes (interface / url / subscription) need different inputs
	// (a resolved netdev, a parsed share-link, a fetched file) that we don't
	// have here — refuse them with a clear error rather than silently emit
	// half a config.
	if (t === "interface" || t === "url" || t === "subscription")
		fail("export_section does not support type=" + t);
	let helpers;
	try { helpers = require("helpers"); } catch (e) { fail("require(helpers) failed"); }
	if (!helpers.is_outbound_proxy_kind(t))
		fail("unknown outbound type: " + (length(t) ? t : "<empty>"));
	let mod;
	try { mod = require("outbound"); } catch (e) { fail("require(outbound) failed"); }
	let ob = mod.build_constructor_for(section, t);
	if (!ob) fail("build_constructor_for returned null");
	emit({ status: "ok", section: scrubbed(ob) });
}
