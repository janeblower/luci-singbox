// lib/plugins/awg_warp/reconcile.uc — native amneziawg interface reconciler.
// No /etc/config/network. Builds interfaces with ip+awg directly (spec §11).
// Idempotent; safe to re-run each apply. ip/awg via env seams for tests.
// Definition order: callee must appear above caller (ucode top-level rule).
let fs        = require("fs");
let ifaceh    = require("plugins.awg_warp.iface");
let confstore = require("plugins.awg_warp.confstore");

const IP_BIN  = getenv("IP_BIN")  || "ip";
const AWG_BIN = getenv("AWG_BIN") || "awg";

// --- shell helpers ---
function sh(cmd)    { return system(cmd + " >/dev/null 2>&1"); }
function sh_ok(cmd) { return system(cmd + " >/dev/null 2>&1") === 0; }

// --- input sanitizers (HIGH-severity injection guards) ---

// safe_cidr — allow IPv4/IPv6 with optional /prefixlen; reject everything else.
// warp_address_v4/v6 may come from stored .conf on selfhosted targets.
// Note: ucode has no (?:...) non-capturing groups; /[0-9]+/ used for prefixlen
// (an over-long prefix is rejected downstream by `ip` itself).
function safe_cidr(s) {
	s = `${s ?? ""}`;
	if (length(s) == 0) return "";
	if (match(s, /^[0-9a-fA-F:.]+\/[0-9]+$/)) return s;
	if (match(s, /^[0-9a-fA-F:.]+$/)) return s;
	require("log").log_event("warn", "awg.unsafe_cidr_rejected", { value: s });
	return "";
}

// safe_endpoint — allow host:port chars; reject anything else (including newlines).
// A newline in the endpoint would inject extra setconf directives (e.g. a second
// [Peer] / AllowedIPs) into the file fed to `awg setconf`.
// '-' is placed last in the class to avoid being read as a range.
function safe_endpoint(s) {
	s = `${s ?? ""}`;
	if (length(s) == 0) return "";
	if (match(s, /^[a-zA-Z0-9._:-]+$/)) return s;
	require("log").log_event("warn", "awg.unsafe_endpoint_rejected", { value: s });
	return "";
}

// --- UCI helpers ---

// _managed_names — enumerate awg_warp outbound sections from UCI.
// Interface names are sanitized via iface_name() (HIGH-severity injection vector).
// del_v6 is sourced from the stored .conf (NOT from UCI warp_address_v6) so that
// addrlabel cleanup works even after UCI cred fields are removed.
function _managed_names(cur) {
	let names = [];
	cur.foreach("singbox-ui", "outbound", function(s) {
		if (s.type != "awg_warp") return;
		let sec = s[".name"];
		// v6 for addrlabel-del: read from stored .conf (if present), not from UCI.
		let v6 = "";
		let storage = (s.warp_storage == "flash") ? "flash" : "ram";
		let raw = fs.readfile(confstore.conf_path(sec, storage));
		if (raw != null && length(raw)) {
			let wg = confstore.parse_full(raw);
			if (wg != null) v6 = wg.address_v6 ?? "";
		}
		push(names, {
			sec:     sec,
			iface:   ifaceh.iface_name(sec),
			s:       s,
			enabled: (s.enabled != "0"),
			del_v6:  v6,
		});
	});
	return names;
}

// --- bring-up steps (called in order by _bring_up) ---

// _create_link — idempotent pre-clean then create the amneziawg interface.
// Returns false if link add fails (caller aborts).
function _create_link(dev) {
	sh("modprobe amneziawg");
	sh(sprintf("%s link del dev %s", IP_BIN, dev));  // ignore failure — may not exist
	if (!sh_ok(sprintf("%s link add dev %s type amneziawg", IP_BIN, dev))) {
		require("log").log_event("error", "awg.iface_add_failed", { iface: dev });
		return false;
	}
	return true;
}

// _apply_setconf — write genl-only tmpfile and load it via awg setconf.
// Address/MTU must not appear in this file — awg setconf is genl-only.
// Rendered via confstore.render_setconf (wg is the flat wgconf object).
function _apply_setconf(dev, wg) {
	let TMPDIR = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
	fs.mkdir(TMPDIR);
	let path = sprintf("%s/%s.setconf", TMPDIR, dev);
	let f = fs.open(path, "w");
	if (f) { f.write(confstore.render_setconf(wg)); f.close(); }
	sh(sprintf("%s setconf %s %s", AWG_BIN, dev, path));
}

// _assign_addresses — ip addr add for v4 (always) and v6 (when ipv6 enabled).
// Takes pre-sanitized addresses (safe_cidr applied by caller).
function _assign_addresses(dev, v4, v6, ipv6) {
	sh(sprintf("%s -4 addr add %s dev %s", IP_BIN, v4, dev));
	if (ipv6) sh(sprintf("%s -6 addr add %s dev %s", IP_BIN, v6, dev));
}

// _set_mtu_up — set MTU and bring the interface up in one step.
function _set_mtu_up(dev, mtu) {
	sh(sprintf("%s link set mtu %d up dev %s", IP_BIN, mtu, dev));
}

// _add_addrlabels — per-interface addrlabel entries for IPv6 source-address
// selection (gated on ipv6 being enabled; caller decides).
function _add_addrlabels(v6) {
	sh(sprintf("%s addrlabel add prefix %s label 100", IP_BIN, v6));
	sh(sprintf("%s addrlabel add prefix ::/0 label 100", IP_BIN));
}

// _bring_up — orchestrate bring-up for one amneziawg interface (spec §11).
// Creds come from confstore.ensure (stored .conf is source of truth, NOT UCI).
// Sanitizers safe_cidr/safe_endpoint are applied to wg.* after ensure() returns.
// NO default routes — sing-box handles egress via bind_interface (spec §16).
function _bring_up(cur, item) {
	let s        = item.s;
	let dev      = item.iface;  // already sanitized by iface_name() in _managed_names
	let mtu      = ifaceh.effective_mtu(cur, s.mtu_override);
	let ipv6_want = (s.ipv6_enabled == "1");

	let wg = confstore.ensure(cur, item, mtu, ipv6_want);
	if (wg == null) return;  // register fail / selfhosted missing / parse fail

	// Sanitize addresses and endpoint from wg (HIGH-severity injection guards).
	let v4 = safe_cidr(wg.address_v4 ?? "172.16.0.2/32");
	let v6 = safe_cidr(wg.address_v6 ?? "");
	let ep = safe_endpoint(wg.endpoint ?? "");
	if (length(v4) == 0) {
		require("log").log_event("error", "awg.bad_address_v4", { iface: dev });
		return;
	}
	if (length(ep) == 0) {
		require("log").log_event("error", "awg.bad_endpoint", { iface: dev });
		return;
	}
	wg.address_v4 = v4; wg.address_v6 = v6; wg.endpoint = ep;
	let ipv6 = ipv6_want && length(v6);

	if (!_create_link(dev)) return;
	_apply_setconf(dev, wg);
	_assign_addresses(dev, v4, v6, ipv6);
	_set_mtu_up(dev, mtu);
	if (ipv6) _add_addrlabels(v6);
}

// _del_iface — remove one amneziawg interface and its addrlabel entries.
// v6_addr is re-sanitized here — callers pass values from stored .conf (HIGH-severity:
// a crafted address_v6 in .conf could inject into `ip addrlabel del`).
// A malformed value sanitizes to "" → addrlabel del is skipped (safe, since
// no valid label was added for a malformed address).
function _del_iface(dev, v6_addr) {
	sh(sprintf("%s link del dev %s", IP_BIN, dev));
	let v6 = safe_cidr(v6_addr);
	if (length(v6)) {
		sh(sprintf("%s addrlabel del prefix %s label 100", IP_BIN, v6));
		sh(sprintf("%s addrlabel del prefix ::/0 label 100", IP_BIN));
	}
}

// apply — idempotent: bring up all enabled awg_warp ifaces, remove orphans.
function apply(cur) {
	let items = _managed_names(cur);
	let want = {};
	for (let it in items) {
		if (it.enabled) {
			want[it.iface] = true;
			_bring_up(cur, it);
		}
	}
	// Remove disabled sections; also clean up addrlabel entries to avoid
	// IPv6 source-address selection corruption (FIX: addrlabel leak on disable).
	for (let it in items) {
		if (!it.enabled && !want[it.iface]) {
			_del_iface(it.iface, it.del_v6);
		}
	}
}

// teardown — remove all managed amneziawg ifaces + their addrlabel entries.
function teardown(cur) {
	for (let it in _managed_names(cur)) {
		_del_iface(it.iface, it.del_v6);
	}
}

return { apply, teardown };
