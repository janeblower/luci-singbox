import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Port of tests/backend/test_defaults.sh
// Runs generate.uc over the SHIPPED default config on the guest, then asserts
// the produced sing-box JSON contains the expected structural elements.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SB_BACKEND_ROOT = `${WORK}/singbox-ui/root`;
const SB_SHARE = `${SB_BACKEND_ROOT}/usr/share/singbox-ui`;
const DEFAULT_CFG = `${SB_BACKEND_ROOT}/etc/config/singbox-ui`;
const GENERATE_UC = `${SB_SHARE}/generate.uc`;

describe("defaults", () => {
  useGuest();

  it("generate.uc over shipped default config produces correct sing-box JSON", async () => {
    // Set up sandbox directories and run generate.uc
    const cmd = `
set -e
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"
mkdir -p "$SANDBOX_DIR/subs"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"

cp '${DEFAULT_CFG}' "$TMPDIR/singbox-ui"

cd '${WORK}'
UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \\
    ucode -L '${LIB}' '${GENERATE_UC}' >"$TMPDIR/gen.stderr" 2>&1 || {
        echo "GENERATE_FAILED"; cat "$TMPDIR/gen.stderr"; exit 1; }

OUT=$(cat "$SANDBOX_CONFIG")

check() {
    echo "$OUT" | grep -q "$1" || { echo "CHECK_FAIL: $2 — $1"; exit 1; }
}

# -- inbound: tproxy + hijack-dns
check '"type": "tproxy"'  'tproxy inbound'
check '"listen_port": 7893'  'tproxy port'
check '"action": "hijack-dns"'  'hijack-dns'

# -- rule-sets: russia_inside + discord
check '"tag": "russia_inside"'  'russia_inside tag'
check '"tag": "discord"'  'discord tag'

# -- outbound direct_wan + route rule
check '"tag": "direct_wan"'  'direct_wan tag'
check '"bind_interface": "wan"'  'direct_wan bind'
check '"outbound": "direct_wan"'  'route to wan'

# -- dns: fakeip + google + rule + final
check '"type": "fakeip"'  'fakeip server'
check '"server": "8.8.8.8"'  'google server'
check '"action": "route"'  'dns rule'
check '"final": "google"'  'dns final'
check '"strategy": "prefer_ipv4"'  'dns strategy'

# No DNS detour to implicit direct
if echo "$OUT" | grep -q '"detour":'; then
    echo "CHECK_FAIL: default DNS must not detour to implicit outbound"
    exit 1
fi

# -- cache: enabled with fakeip storage
check '"cache_file":'  'cache enabled'
check '"path": "/tmp/singbox-ui-cache.db"'  'cache path /tmp'
check '"store_fakeip": true'  'cache store_fakeip'

# -- dns inbound: dns_in direct listener
check '"type": "direct"'  'dns inbound type'
check '"tag": "dns_in"'  'dns inbound tag'
check '"listen": "127.0.0.53"'  'dns inbound listen'
check '"listen_port": 53'  'dns inbound port'
check '"action": "hijack-dns"'  'default hijack-dns rule'

echo "OK"
`;
    const r = await exec(cmd);
    // Show any error output for diagnostics
    if (r.exitCode !== 0) {
      throw new Error(
        `defaults test failed (exit ${r.exitCode})\nstdout: ${r.stdout}\nstderr: ${r.stderr}`,
      );
    }
    expect(r.stdout).toContain("OK");
  });

  it("sing-box check accepts generated default config", async () => {
    // Skipped if sing-box is not installed in the VM
    const checkCmd = await exec(
      "command -v sing-box >/dev/null 2>&1 && echo yes || echo no",
    );
    if (checkCmd.stdout.trim() !== "yes") {
      // sing-box not installed — skip
      return;
    }

    const cmd = `
set -e
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"
mkdir -p "$SANDBOX_DIR/subs"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"
cp '${DEFAULT_CFG}' "$TMPDIR/singbox-ui"
cd '${WORK}'
UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \\
    ucode -L '${LIB}' '${GENERATE_UC}' >/dev/null 2>&1
sing-box check -c "$SANDBOX_CONFIG" >/dev/null 2>&1 && echo "CHECKOK" || echo "CHECKFAIL"
`;
    const r = await exec(cmd);
    expect(r.stdout).toContain("CHECKOK");
  });
});
