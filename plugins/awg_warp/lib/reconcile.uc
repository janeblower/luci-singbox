// lib/plugins/awg_warp/reconcile.uc — native amneziawg interface reconciler.
// No /etc/config/network. Builds interfaces with ip+awg directly (spec §11).
// Idempotent; safe to re-run each apply. ip/awg via env seams for tests.
// Definition order: callee must appear above caller (ucode top-level rule).
let fs     = require("fs");
let ifaceh = require("plugins.awg_warp.iface");

const IP_BIN  = getenv("IP_BIN")  || "ip";
const AWG_BIN = getenv("AWG_BIN") || "awg";
const TMPDIR  = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";

// --- shell helpers ---
function sh(cmd)    { return system(cmd + " >/dev/null 2>&1"); }
function sh_ok(cmd) { return system(cmd + " >/dev/null 2>&1") === 0; }

// --- input sanitizers (HIGH-severity injection guards) ---

// safe_cidr — allow IPv4/IPv6 with optional /prefixlen; reject everything else.
// warp_address_v4/v6 may be user-supplied on selfhosted targets.
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

// --- setconf renderers ---

// render_setconf — genl-only setconf for `awg setconf`.
// Address and MTU are intentionally absent: awg setconf is genl-only and
// rejects those fields; they are applied separately via `ip addr` / `ip link`.
function render_setconf(creds, p) {
	let s = "[Interface]\n";
	s += sprintf("PrivateKey = %s\n", creds.private_key ?? "");
	s += sprintf("Jc = %d\nJmin = %d\nJmax = %d\n", p.jc, p.jmin, p.jmax);
	s += sprintf("S1 = %d\nS2 = %d\nS3 = %d\nS4 = %d\n", p.s1, p.s2, p.s3, p.s4);
	s += sprintf("H1 = %d\nH2 = %d\nH3 = %d\nH4 = %d\n", p.h1, p.h2, p.h3, p.h4);
	if (length(`${p.i1 ?? ""}`)) s += sprintf("I1 = %s\n", p.i1);
	s += "[Peer]\n";
	s += sprintf("PublicKey = %s\n", creds.peer_public_key ?? "");
	s += sprintf("Endpoint = %s\n", creds.endpoint ?? "");
	s += "AllowedIPs = 0.0.0.0/0, ::/0\n";
	s += "PersistentKeepalive = 25\n";
	return s;
}

// render_conf — human-readable conf for storage (NOT fed to awg setconf).
// v6 Address is commented out (#) when ipv6_enabled is false (spec §2.5).
// Address + MTU are inserted before [Peer] for readability.
function render_conf(creds, p, ipv6_enabled) {
	let setconf = render_setconf(creds, p);
	let addr = sprintf("Address = %s", creds.address_v4 ?? "172.16.0.2/32");
	if (length(`${creds.address_v6 ?? ""}`))
		addr += "\n" + (ipv6_enabled ? "" : "#") + sprintf("Address = %s", creds.address_v6);
	return replace(setconf, "[Peer]", sprintf("%s\nMTU = %d\n[Peer]", addr, p.mtu));
}

// --- UCI helpers ---

// _params_from_section — derive genl params from a UCI outbound section.
// For target=warp: S/H use WARP-safe defaults (spec §10).
// For selfhosted: read stored awg_s*/awg_h* from UCI (expert-only, no product UI).
function _params_from_section(s) {
	function n(k, d) { let v = int(`${s[k] ?? ""}`); return (v != 0 || s[k] == "0") ? v : d; }
	let target = (s.awg_target == "selfhosted") ? "selfhosted" : "warp";
	let p = {
		jc:   n("awg_jc",   8),
		jmin: n("awg_jmin", 64),
		jmax: n("awg_jmax", 900),
		s1: 0, s2: 0, s3: 0, s4: 0,
		h1: 1, h2: 2, h3: 3, h4: 4,
		i1: s.awg_i1 ?? "",
		mtu: 1280,
	};
	if (target == "selfhosted") {
		p.s1 = n("awg_s1", 0); p.s2 = n("awg_s2", 0);
		p.h1 = n("awg_h1", 1); p.h2 = n("awg_h2", 2);
		p.h3 = n("awg_h3", 3); p.h4 = n("awg_h4", 4);
	}
	return p;
}

// _managed_names — enumerate awg_warp outbound sections from UCI.
// Interface names are sanitized via iface_name() (HIGH-severity injection vector).
function _managed_names(cur) {
	let names = [];
	cur.foreach("singbox-ui", "outbound", function(s) {
		if (s.type != "awg_warp") return;
		push(names, {
			sec:     s[".name"],
			iface:   ifaceh.iface_name(s[".name"]),
			s:       s,
			enabled: (s.enabled != "0"),
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
function _apply_setconf(dev, creds, p) {
	fs.mkdir(TMPDIR);
	let path = sprintf("%s/%s.setconf", TMPDIR, dev);
	let f = fs.open(path, "w");
	if (f) { f.write(render_setconf(creds, p)); f.close(); }
	sh(sprintf("%s setconf %s %s", AWG_BIN, dev, path));
}

// _assign_addresses — ip addr add for v4 (always) and v6 (when ipv6 enabled).
function _assign_addresses(dev, creds, ipv6) {
	sh(sprintf("%s -4 addr add %s dev %s", IP_BIN, creds.address_v4, dev));
	if (ipv6) sh(sprintf("%s -6 addr add %s dev %s", IP_BIN, creds.address_v6, dev));
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
// Validates credentials, then delegates each step to a named helper.
// NO default routes — sing-box handles egress via bind_interface (spec §16).
function _bring_up(cur, item) {
	let s   = item.s;
	let dev = item.iface;  // already sanitized by iface_name() in _managed_names
	let p   = _params_from_section(s);
	p.mtu   = ifaceh.effective_mtu(cur, s.mtu_override);
	let creds = {
		private_key:     s.warp_private_key      ?? "",
		peer_public_key: s.warp_peer_public_key  ?? "",
		address_v4:      safe_cidr(s.warp_address_v4 ?? "172.16.0.2/32"),
		address_v6:      safe_cidr(s.warp_address_v6 ?? ""),
		endpoint:        safe_endpoint(s.warp_endpoint ?? "engage.cloudflareclient.com:2408"),
	};
	// Abort if address or endpoint is malformed — tunnel cannot work without them.
	if (length(creds.address_v4) == 0) {
		require("log").log_event("error", "awg.bad_address_v4", { iface: dev });
		return;
	}
	if (length(creds.endpoint) == 0) {
		require("log").log_event("error", "awg.bad_endpoint", { iface: dev });
		return;
	}
	let ipv6 = (s.ipv6_enabled == "1") && length(creds.address_v6);

	if (!_create_link(dev)) return;
	_apply_setconf(dev, creds, p);
	_assign_addresses(dev, creds, ipv6);
	_set_mtu_up(dev, p.mtu);
	if (ipv6) _add_addrlabels(creds.address_v6);
}

// _del_iface — remove one amneziawg interface and its addrlabel entries.
// v6_addr is re-sanitized here — callers pass raw UCI values (HIGH-severity:
// a crafted warp_address_v6 could inject into `ip addrlabel del`).
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
			_del_iface(it.iface, it.s.warp_address_v6);
		}
	}
}

// teardown — remove all managed amneziawg ifaces + their addrlabel entries.
function teardown(cur) {
	for (let it in _managed_names(cur)) {
		_del_iface(it.iface, it.s.warp_address_v6);
	}
}

return { apply, teardown, render_setconf, render_conf };
