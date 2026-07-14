import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

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

# -- the seeded tun_in is DISABLED and must not reach the config. It is the
# ALTERNATIVE to the tproxy inbound above, not a companion: system routing has
# exactly one owner, and if this one ever emitted, generate.uc would refuse to
# build at all (rc 3, both claim the "transparent" group) and the box would come
# up with no config. Shipping it enabled would also change how a fresh install
# behaves — you flip two toggles to switch, deliberately.
echo "$OUT" | grep -q '"type": "tun"' && { echo "CHECK_FAIL: the seeded tun_in must ship DISABLED"; exit 1; }

# -- The shipped config carries NO routing opinion: no outbound, no route rule,
# no route_default, no dns_rule. The routing it used to ship was wrong in the
# direction that silently does nothing: it sent russia_inside — the itdoginfo list
# of what is BLOCKED for a user in Russia — straight out the WAN, i.e. around the
# proxy. A correct default cannot be shipped either: it must point at a proxy, and
# a fresh install has none. So the box comes up with the 25 built-in rule-sets
# ready and no opinion about how to use them.
#
# The one outbound in the config is the implicit "direct" that generate.uc injects,
# and sing-box is happy with that: traffic flows, nothing is proxied.
echo "$OUT" | grep -q '"rule_set":' && { echo "CHECK_FAIL: the shipped config must reference no rule-sets"; exit 1; }
echo "$OUT" | grep -q '"tag": "wan"' && { echo "CHECK_FAIL: the shipped config must ship no wan outbound"; exit 1; }
echo "$OUT" | grep -q '"final":.*"wan"' && { echo "CHECK_FAIL: the shipped config must set no default route"; exit 1; }
check '"tag": "direct"'  'the implicit direct outbound is injected'

# -- dns: fakeip + google + final. fakeip is DEFINED but nothing points at it:
# fakeip without routing hands the client a 198.18.x.x address that only means
# something once the connection is captured and mapped back, so a fakeip dns_rule
# with no matching route rule would simply kill those domains.
check '"type": "fakeip"'  'fakeip server'
check '"server": "8.8.8.8"'  'google server'
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

  it("enabling the seeded tun_in, with nothing else changed, does not trip the ownership conflict", async () => {
    // REGRESSION GUARD (F1): the seed used to pre-arm `auto_route '1'` +
    // `auto_redirect '1'` on the DISABLED tun_in. Those are `modalonly`
    // fields, but `enabled` is a live checkbox in the inbounds GRID — so a
    // user could flip tun_in on WITHOUT ever opening the modal, leaving the
    // pre-armed auto_route in UCI untouched. That reproduces exactly: seed +
    // `enabled '1'` on tun_in and nothing else. tun_in (auto_route='1') and
    // the seeded, enabled tproxy_in (nft_rules default-on) then both claimed
    // system routing -> generate.uc's ownership guard refused (rc 3) ->
    // init.d would not (re)start on that refusal -> the LAN egresses
    // unproxied. The one-line fix: the seed no longer writes auto_route /
    // auto_redirect, so an enabled-from-the-grid tun_in is inert (no
    // routing), not conflicting.
    const cmd = `
set -e
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT
SANDBOX_DIR="$TMPDIR/sandbox"
mkdir -p "$SANDBOX_DIR/subs"
SANDBOX_CONFIG="$SANDBOX_DIR/singbox-ui.json"

cp '${DEFAULT_CFG}' "$TMPDIR/singbox-ui"

# The one click: flip tun_in.enabled via UCI, exactly what the grid checkbox
# does. Nothing else in the seed changes — in particular the modalonly
# auto_route field is never touched.
uci -c "$TMPDIR" set singbox-ui.tun_in.enabled=1
uci -c "$TMPDIR" commit singbox-ui

cd '${WORK}'
set +e
UCI_CONFIG_DIR="$TMPDIR" SINGBOX_TMPDIR="$SANDBOX_DIR/subs" SINGBOX_CONFIG="$SANDBOX_CONFIG" \\
    ucode -L '${LIB}' '${GENERATE_UC}' >"$TMPDIR/gen.stdout" 2>"$TMPDIR/gen.stderr"
RC=$?
set -e

echo "GENERATE_RC=$RC"
cat "$TMPDIR/gen.stderr"

if [ "$RC" -eq 3 ]; then
    echo "CHECK_FAIL: ownership conflict (rc 3) — tun_in.auto_route and tproxy_in.nft_rules both claim system routing"
    exit 1
fi
if [ "$RC" -ne 0 ]; then
    echo "CHECK_FAIL: generate.uc must succeed (rc 0) with tun_in enabled and nothing else changed"
    exit 1
fi

echo "OK"
`;
    const r = await exec(cmd);
    if (r.exitCode !== 0) {
      throw new Error(
        `enabling tun_in must not trip the ownership conflict (exit ${r.exitCode})\nstdout: ${r.stdout}\nstderr: ${r.stderr}`,
      );
    }
    expect(r.stdout).toContain("GENERATE_RC=0");
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
