// lib/plugins/awg_warp/init.uc — AWG-WARP plugin registration entry.
// Wires all hooks (descriptor, lifecycle, nft fragment) and the 2 rpcd methods.
// Called by plugins.discovery.load_all(); require() caches prevent double-init.

let reg      = require("plugins.registry");

let reconcile = require("plugins.awg_warp.reconcile");
let nft       = require("plugins.awg_warp.nft");
require("plugins.awg_warp.protocols.awg_warp");   // self-registers the outbound type

// ── env-overridable seams (test + prod) ──────────────────────────────────────
// SB_AWG_PROVISION overrides the provisioning script path (for tests).
const PROVISION_SH = getenv("SB_AWG_PROVISION")
                     || "/usr/libexec/singbox-ui/awg-provision.sh";

// ── helpers ──────────────────────────────────────────────────────────────────

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
	let rc = system(sprintf("%s >/dev/null 2>&1", PROVISION_SH));
	if (rc !== 0) {
		emit({ status: "error", message: sprintf("provision script failed (rc=%d)", rc) });
		return;
	}
	emit({ status: "ok" });
}

// ── plugin registration ───────────────────────────────────────────────────────
reg.register({
	name:        "awg_warp",
	version:     "1",
	descriptors: true,

	rpcd: {
		methods: {
			awg_status:  m_awg_status,
			awg_install: m_awg_install,
		},
		acl_read:  ["awg_status"],
		acl_write: ["awg_install"],
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
