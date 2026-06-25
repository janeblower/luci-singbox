// lib/plugins/awg_warp/iface.uc — interface-name derivation + MTU computation.
// Interface names come from UCI and are a HIGH-severity injection vector — every
// name passes through iface_name() before reaching `ip`/`awg`.
let fs = require("fs");

// _read_int must be defined before wan_mtu (ucode resolves top-level functions
// in definition order — callee must appear above caller).
function _read_int(path) {
	let f = fs.open(path, "r");
	if (!f) return null;
	let v = trim(f.read("all") ?? "");
	f.close();
	let n = int(v);
	return (n > 0) ? n : null;
}

// iface_name: sanitize a UCI section name to a valid Linux interface name.
// Keeps only [a-z0-9_], lowercases, truncates to 15 chars, falls back to "awg".
function iface_name(section) {
	let s = lc(`${section ?? ""}`);
	let out = "";
	for (let i = 0; i < length(s); i++) {
		let c = substr(s, i, 1);
		if (match(c, /[a-z0-9_]/)) out += c;
	}
	if (length(out) > 15) out = substr(out, 0, 15);
	if (!length(out)) out = "awg";
	return out;
}

// wan_mtu: read the WAN device MTU from sysfs. Falls back to 1500.
// Env seams: SB_WAN_DEV (device name override), SB_SYS_NET (sysfs net root).
function wan_mtu(cur) {
	let sysnet = getenv("SB_SYS_NET") || "/sys/class/net";
	let dev = getenv("SB_WAN_DEV");
	if (dev == null || !length(dev)) {
		// resolve wan L3 device via ubus network.interface.wan
		let p = fs.popen("ubus call network.interface.wan status 2>/dev/null");
		if (p) {
			let body = p.read("all") ?? "";
			p.close();
			try {
				let j = json(body);
				if (j != null && length(j.l3_device)) dev = j.l3_device;
			} catch (_) {}
		}
	}
	if (dev != null && length(dev)) {
		let m = _read_int(sysnet + "/" + dev + "/mtu");
		if (m != null) return m;
	}
	return 1500;
}

// effective_mtu: use override if positive int, else WAN MTU minus 80 overhead.
function effective_mtu(cur, override) {
	let ov = int(`${override ?? ""}`);
	if (ov > 0) return ov;
	return wan_mtu(cur) - 80;
}

return { iface_name, wan_mtu, effective_mtu };
