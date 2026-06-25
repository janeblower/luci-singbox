// lib/plugins/awg_warp/init.uc — AWG-WARP plugin registration entry.
// Wires all hooks (descriptor, lifecycle, nft fragment) and the 4 rpcd methods.
// Called by plugins.discovery.load_all(); require() caches prevent double-init.

let reg      = require("plugins.registry");
let fs       = require("fs");
let helpers  = require("helpers");

let reconcile = require("plugins.awg_warp.reconcile");
let nft       = require("plugins.awg_warp.nft");
let warp      = require("plugins.awg_warp.warp");
let awggen    = require("plugins.awg_warp.awggen");
let ifaceh    = require("plugins.awg_warp.iface");
require("plugins.awg_warp.protocols.awg_warp");   // self-registers the outbound type

// ── env-overridable seams (test + prod) ──────────────────────────────────────
const FEED_KEY  = getenv("SB_AWG_FEED_KEY")
                  || "/usr/share/singbox-ui/lib/plugins/awg_warp/awg-openwrt-feed.pem";
const APK_CMD   = getenv("APK_CMD")      || "apk";
const KEYS_DIR  = getenv("SB_APK_KEYS") || "/etc/apk/keys";
const REPOS     = getenv("SB_APK_REPOS") || "/etc/apk/repositories";
// SB_UBUS_BOARD overrides the board-query command (e.g. a stub script in tests).
const BOARD_CMD = getenv("SB_UBUS_BOARD") || "ubus call system board";

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

// ── board helper ─────────────────────────────────────────────────────────────
// _board: call `ubus call system board` (or SB_UBUS_BOARD stub) and return
// parsed JSON, or {} on error.
// Must be defined before m_awg_install (definition-order rule).
function _board() {
	let p = fs.popen(BOARD_CMD + " 2>/dev/null");
	if (!p) return {};
	let body = p.read("all") ?? "";
	p.close();
	let j;
	try { j = json(body); } catch (e) { j = {}; }
	return (type(j) === "object") ? j : {};
}

// ── rpcd method: awg_install ─────────────────────────────────────────────────
// Self-provision: copy feed key, append awg repo, apk update + add packages.
// Idempotent (duplicate repo line check; apk add is idempotent by design).
function m_awg_install() {
	// 1) Copy the bundled feed public key into the apk key store.
	system(sprintf("mkdir -p %s", helpers.sq(KEYS_DIR)));
	let cp_rc = system(sprintf("cp %s %s/awg-openwrt-feed.pem 2>/dev/null",
	                           helpers.sq(FEED_KEY), helpers.sq(KEYS_DIR)));
	if (cp_rc !== 0) {
		emit({ status: "error", message: sprintf("key copy failed (rc=%d); key: %s", cp_rc, FEED_KEY) });
		return;
	}

	// 2) Resolve the board target from ubus and build the feed URL.
	//    release.target is e.g. "x86/64"; fall back gracefully.
	//    SECURITY: board JSON comes from root-local firmware data, but we
	//    validate strictly to prevent a crafted target containing newlines or
	//    URL metacharacters from injecting extra lines into /etc/apk/repositories.
	//    Accepted pattern: "<subtarget>/<arch>" where each component is
	//    lowercase alnum plus "_"/"-", at least one char each.
	let board  = _board();
	let target = "";
	let rel = board.release;
	if (type(rel) === "object" && length(`${rel.target ?? ""}`))
		target = rel.target;
	// Reject any target that does not match the strict OpenWrt target pattern.
	// Non-capturing groups are not supported in ucode regex; use plain char classes.
	if (!match(target, /^[a-z0-9][a-z0-9_-]*\/[a-z0-9][a-z0-9_-]*$/))
		target = "x86/64";

	// Pin the awg-openwrt train version published at time of plugin build.
	let ver = "25.12.4";
	let url  = sprintf("https://slava-shchipunov.github.io/awg-openwrt/%s/%s/packages.adb",
	                   ver, target);
	let line = sprintf("%s awg", url);

	// Append repo line idempotently.
	let cur_repos = "";
	let rf = fs.open(REPOS, "r");
	if (rf) { cur_repos = rf.read("all") ?? ""; rf.close(); }
	if (index(cur_repos, url) < 0) {
		let wf = fs.open(REPOS, "a");
		if (wf) { wf.write("\n" + line + "\n"); wf.close(); }
	}

	// 3) apk update.
	system(sprintf("%s update >/dev/null 2>&1", helpers.sq(APK_CMD)));

	// 4) apk add the three required packages.
	let rc = system(sprintf("%s add ip-full kmod-amneziawg amneziawg-tools >/dev/null 2>&1",
	                        helpers.sq(APK_CMD)));
	if (rc !== 0) {
		emit({ status: "error", message: sprintf("apk add failed (rc=%d)", rc) });
		return;
	}

	// 5) Load the kernel module (best-effort; may already be loaded).
	system("modprobe amneziawg >/dev/null 2>&1");
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
