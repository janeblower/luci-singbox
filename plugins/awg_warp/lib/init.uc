// lib/plugins/awg_warp/init.uc — AWG-WARP plugin registration entry.
// Wires all hooks (descriptor, lifecycle, nft fragment) and the 4 rpcd methods.
// Called by plugins.discovery.load_all(); require() caches prevent double-init.

let reg      = require("plugins.registry");
let fs       = require("fs");

let reconcile = require("plugins.awg_warp.reconcile");
let nft       = require("plugins.awg_warp.nft");
let warp      = require("plugins.awg_warp.warp");
let awggen    = require("plugins.awg_warp.awggen");
let ifaceh    = require("plugins.awg_warp.iface");
require("plugins.awg_warp.protocols.awg_warp");   // self-registers the outbound type

// ── env-overridable seams (test + prod) ──────────────────────────────────────
// SB_AWG_PROVISION overrides the provisioning script path (for tests).
const PROVISION_SH = getenv("SB_AWG_PROVISION")
                     || "/usr/libexec/singbox-ui/awg-provision.sh";

// ── helpers ──────────────────────────────────────────────────────────────────

// _args: read stdin once and parse as JSON object (mirrors parse_args() style).
// The framework handler calls plugin methods with NO args; they read stdin themselves.
function _args() {
	let raw = "";
	try { raw = fs.stdin.read("all") || ""; } catch (e) {}
	let v;
	try { v = json(raw); } catch (e) { v = {}; }
	return (type(v) === "object") ? v : {};
}

// emit: write one JSON line to stdout (standard rpcd wire format).
function emit(o) { printf("%J\n", o); }

// ── rpcd method: awg_status ──────────────────────────────────────────────────
// Read-only probe: reports whether amneziawg kmod, awg tool, and ip are present.
function m_awg_status() {
	let has_kmod = (system("test -d /sys/module/amneziawg >/dev/null 2>&1") === 0)
	               || (system("modinfo amneziawg >/dev/null 2>&1") === 0);
	let has_awg  = (system("command -v awg >/dev/null 2>&1") === 0);
	let has_ip   = (system("ip -V >/dev/null 2>&1") === 0);
	emit({ status: "ok", ready: (has_kmod && has_awg && has_ip),
	       has_awg, has_ip, has_kmod });
}

// ── rpcd method: awg_install ─────────────────────────────────────────────────
// Thin wrapper: delegates all provisioning logic to awg-provision.sh.
// The script is env-overridable (SB_AWG_PROVISION) for test injection.
function m_awg_install() {
	let rc = system(sprintf("%s 2>&1", PROVISION_SH));
	if (rc !== 0) {
		emit({ status: "error", message: sprintf("provision script failed (rc=%d)", rc) });
		return;
	}
	emit({ status: "ok" });
}

// ── rpcd method: warp_register ───────────────────────────────────────────────
// Trigger a WARP registration (auto or paste) and store credentials in UCI.
function m_warp_register() {
	let a   = _args();
	let sec = a.outbound;
	if (type(sec) !== "string" || !match(sec, /^[a-zA-Z0-9_]+$/))
		return emit({ status: "error", message: "bad outbound name" });

	let res;
	if (a.mode === "paste") {
		res = warp.parse_conf(a.conf ?? "");
	} else {
		res = warp.register_auto();
	}
	if (!res.ok)
		return emit({ status: "error", message: res.error ?? "registration failed" });

	let uci_dir = getenv("UCI_CONFIG_DIR");
	let cur = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
	warp.store_creds(cur, sec, res.creds);
	// Contract: creds are committed here; the native amneziawg interface is
	// (re)built on the NEXT init.d apply (lifecycle hook), consistent with the
	// Save&Apply model — do NOT trigger reconcile here (would double-apply).
	emit({ status: "ok" });
}

// ── rpcd method: awg_generate ────────────────────────────────────────────────
// Re-roll AmneziaWG obfuscation params and write back to UCI.
function m_awg_generate() {
	let a   = _args();
	let sec = a.outbound;
	if (type(sec) !== "string" || !match(sec, /^[a-zA-Z0-9_]+$/))
		return emit({ status: "error", message: "bad outbound name" });

	let uci_dir = getenv("UCI_CONFIG_DIR");
	let cur = uci_dir ? require("uci").cursor(uci_dir) : require("uci").cursor();
	let s = {};
	cur.foreach("singbox-ui", "outbound", function(x) { if (x[".name"] === sec) s = x; });

	let p = awggen.generate({
		target: (s.awg_target === "selfhosted") ? "selfhosted" : "warp",
		mimic:  s.awg_mimic ?? "auto",
		mtu:    ifaceh.effective_mtu(cur, s.mtu_override),
	});

	cur.set("singbox-ui", sec, "awg_jc",   sprintf("%d", p.jc));
	cur.set("singbox-ui", sec, "awg_jmin", sprintf("%d", p.jmin));
	cur.set("singbox-ui", sec, "awg_jmax", sprintf("%d", p.jmax));
	cur.set("singbox-ui", sec, "awg_i1",   p.i1);
	cur.commit("singbox-ui");
	emit({ status: "ok", jc: p.jc, jmin: p.jmin, jmax: p.jmax });
}

// ── plugin registration ───────────────────────────────────────────────────────
reg.register({
	name:        "awg_warp",
	version:     "1",
	descriptors: true,

	rpcd: {
		methods: {
			awg_status:    m_awg_status,
			awg_install:   m_awg_install,
			warp_register: m_warp_register,
			awg_generate:  m_awg_generate,
		},
		acl_read:  ["awg_status"],
		acl_write: ["warp_register", "awg_install", "awg_generate"],
	},

	lifecycle: {
		apply:    reconcile.apply,
		teardown: reconcile.teardown,
	},

	nft: {
		fragment: nft.fragment,
	},
});

return {};
