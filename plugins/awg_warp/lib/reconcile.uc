// lib/plugins/awg_warp/reconcile.uc — native amneziawg interface reconciler.
// No /etc/config/network. Builds interfaces with ip+awg directly (spec §11).
// Idempotent; safe to re-run each apply. ip/awg via env seams for tests.
// Definition order: helpers must appear above their callers (ucode resolves
// top-level functions in definition order — callee must be above caller).
let fs     = require("fs");
let ifaceh = require("plugins.awg_warp.iface");

const IP_BIN  = getenv("IP_BIN")  || "ip";
const AWG_BIN = getenv("AWG_BIN") || "awg";
const TMPDIR  = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";

function sh(cmd) { return system(cmd + " >/dev/null 2>&1"); }
function sh_ok(cmd) { return system(cmd + " >/dev/null 2>&1") === 0; }

// safe_cidr — sanitize an IP/CIDR string from UCI before it reaches the shell.
// Accepts: IPv4 dotted-decimal, IPv6 hex-colon, with optional /prefixlen.
// Returns the original string if it matches the allowed charset; "" otherwise.
// HIGH-severity: warp_address_v4/v6 may be user-supplied on selfhosted targets.
function safe_cidr(s) {
	s = `${s ?? ""}`;
	if (length(s) == 0) return "";
	// Capturing group (/[0-9]+) is intentional — ucode supports capturing but
	// not non-capturing (?:...) groups. {1,3} quantifier also not supported —
	// use /[0-9]+ instead (prefix length is validated indirectly via the
	// overall CIDR semantics; an over-long prefix is rejected by `ip` itself).
	if (match(s, /^[0-9a-fA-F:.]+\/[0-9]+$/)) return s;
	if (match(s, /^[0-9a-fA-F:.]+$/)) return s;
	require("log").log_event("warn", "awg.unsafe_cidr_rejected", { value: s });
	return "";
}

// safe_endpoint — sanitize warp_endpoint (host:port) before it reaches the
// setconf file fed to `awg setconf`.  Not a shell command, but a crafted value
// containing a NEWLINE could inject extra setconf directives (e.g. a second
// [Peer] / AllowedIPs), violating WARP-tunnel integrity.
// Accepts: hostname/IPv4/bracketless-IPv6-like chars plus colon and port digits.
// Charset ^[a-zA-Z0-9._:-]+$ covers: hostnames, dotted-IPv4, hex-colon-IPv6,
// and :port — no whitespace, newlines, or shell metacharacters are permitted.
// Note: ucode does not support (?:...) non-capturing groups; '-' is placed last
// in the character class to avoid being mis-read as a range.
// Returns the original string if valid; "" otherwise.
function safe_endpoint(s) {
	s = `${s ?? ""}`;
	if (length(s) == 0) return "";
	if (match(s, /^[a-zA-Z0-9._:-]+$/)) return s;
	require("log").log_event("warn", "awg.unsafe_endpoint_rejected", { value: s });
	return "";
}

// render_setconf — genl-only setconf (NO Address/MTU — those go via ip addr/ip link).
// Putting Address/MTU here causes `awg setconf` to fail.
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

// render_conf — full human-facing conf for storage.
// v6 Address line is commented out (#) when ipv6_enabled is false (spec §2.5).
// MTU and Address lines are inserted after PrivateKey block for human readability.
function render_conf(creds, p, ipv6_enabled) {
	let setconf = render_setconf(creds, p);
	let addr = sprintf("Address = %s", creds.address_v4 ?? "172.16.0.2/32");
	if (length(`${creds.address_v6 ?? ""}`))
		addr += "\n" + (ipv6_enabled ? "" : "#") + sprintf("Address = %s", creds.address_v6);
	// insert Address + MTU before [Peer] section (storage view only — not fed to awg setconf)
	return replace(setconf, "[Peer]", sprintf("%s\nMTU = %d\n[Peer]", addr, p.mtu));
}

// _params_from_section — derive genl params from a UCI outbound section.
// For target=warp: S1..S4=0, H1=1,H2=2,H3=3,H4=4 (WARP-safe, spec §10).
// For selfhosted: read stored awg_s*/awg_h* from UCI.
// Note: selfhosted (custom S/H) is EXPERT-UCI-ONLY — no product UI sets
// awg_target=selfhosted (the form is WARP-only); this path exists for
// hand-edited configs / future use.
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

// _managed_names — enumerate all awg_warp outbound sections from UCI.
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

// _bring_up — create and configure one amneziawg interface natively.
// Sequence per spec §11:
//   1. modprobe amneziawg
//   2. ip link del (idempotent pre-clean)
//   3. ip link add dev <dev> type amneziawg
//   4. awg setconf <dev> <genl-only tmpfile>   (NO Address/MTU in file)
//   5. ip -4 addr add <v4> dev <dev>
//   6. ip -6 addr add <v6> dev <dev>           (if ipv6 enabled)
//   7. ip link set mtu <mtu> up dev <dev>
//   8. ip addrlabel add prefix <v6> label 100  (if ipv6 enabled)
//   9. ip addrlabel add prefix ::/0 label 100  (if ipv6 enabled)
// NO default routes added — sing-box handles egress via bind_interface (spec §16).
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
	// Abort if v4 address is malformed (safe_cidr returned "").
	if (length(creds.address_v4) == 0) {
		require("log").log_event("error", "awg.bad_address_v4", { iface: dev });
		return;
	}
	// Abort if endpoint is malformed or contains injection payload (safe_endpoint returned "").
	// The tunnel cannot work without a valid endpoint; skip rather than bring up a broken iface.
	if (length(creds.endpoint) == 0) {
		require("log").log_event("error", "awg.bad_endpoint", { iface: dev });
		return;
	}
	let ipv6 = (s.ipv6_enabled == "1") && length(creds.address_v6);

	// 1. load kernel module
	sh("modprobe amneziawg");
	// 2. idempotent pre-clean (ignore failure — device may not exist)
	sh(sprintf("%s link del dev %s", IP_BIN, dev));
	// 3. create interface
	if (!sh_ok(sprintf("%s link add dev %s type amneziawg", IP_BIN, dev))) {
		require("log").log_event("error", "awg.iface_add_failed", { iface: dev });
		return;
	}
	// 4. apply genl-only setconf (Address/MTU MUST NOT be in this file)
	fs.mkdir(TMPDIR);
	let path = sprintf("%s/%s.setconf", TMPDIR, dev);
	let f = fs.open(path, "w");
	if (f) { f.write(render_setconf(creds, p)); f.close(); }
	sh(sprintf("%s setconf %s %s", AWG_BIN, dev, path));
	// 5. assign IPv4 address
	sh(sprintf("%s -4 addr add %s dev %s", IP_BIN, creds.address_v4, dev));
	// 6. assign IPv6 address (gated on ipv6_enabled)
	if (ipv6) sh(sprintf("%s -6 addr add %s dev %s", IP_BIN, creds.address_v6, dev));
	// 7. set MTU and bring interface up
	sh(sprintf("%s link set mtu %d up dev %s", IP_BIN, p.mtu, dev));
	// 8+9. per-interface addrlabel for IPv6 source address selection (gated on ipv6_enabled)
	if (ipv6) {
		sh(sprintf("%s addrlabel add prefix %s label 100", IP_BIN, creds.address_v6));
		sh(sprintf("%s addrlabel add prefix ::/0 label 100", IP_BIN));
	}
}

// _del_iface — remove one amneziawg interface and its per-interface addrlabel
// entries.  Shared by apply()'s orphan/disable path and teardown() to avoid
// duplicating the addrlabel cleanup logic (FIX: addrlabel leak on disable).
// v6_addr is sanitized here via safe_cidr() — callers pass raw UCI values
// (HIGH-severity: crafted warp_address_v6 could inject into `ip addrlabel del`).
// A malformed value sanitizes to "" → addrlabel del is skipped (safe, since
// no valid label was ever added for a malformed address).
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
	// teardown disabled sections whose iface is not also wanted by an enabled section;
	// also remove addrlabel entries to avoid IPv6 source-address selection corruption.
	for (let it in items) {
		if (!it.enabled && !want[it.iface]) {
			_del_iface(it.iface, it.s.warp_address_v6);
		}
	}
}

// teardown — remove all managed amneziawg ifaces + per-interface addrlabel entries.
function teardown(cur) {
	for (let it in _managed_names(cur)) {
		_del_iface(it.iface, it.s.warp_address_v6);
	}
}

return { apply, teardown, render_setconf, render_conf };
