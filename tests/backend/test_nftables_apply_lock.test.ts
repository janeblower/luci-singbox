import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { exec } from "../helpers/ssh.ts";
import { useGuest } from "../helpers/guest.ts";

// Port of tests/backend/test_nftables_apply_lock.sh
// S1-4: concurrent applies serialize on the mkdir-based lock; stale/SEC-3 guards.
// STATEFUL: manipulates /tmp/singbox-ui/.apply.lock in the guest.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ??
  `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const SCRIPT = `${WORK}/singbox-ui/root/usr/share/singbox-ui/nftables.uc`;

const UCI_CONFIG = `config dns_server fakeip
\toption type 'fakeip'
\toption enabled '1'
\toption inet4_range '198.18.0.0/15'
config inbound tp
\toption protocol 'tproxy'
\toption enabled '1'
\toption nft_rules '1'
\toption listen_port '7895'
\tlist interface 'br-lan'
`;

// Helper: build a run_apply shell function string given a TMPDIR path.
// Uses PATH=STUB:$PATH (double-quoting avoids single-quote $PATH pitfall).
function runApplyFn(td: string): string {
  return `run_apply() {
  PATH="${td}/bin:$PATH" UCI_CONFIG_DIR="${td}/uci" \\
    ucode -L '${LIB}' '${SCRIPT}' apply >/dev/null 2>"$1"
}`;
}

let TMPDIR = "";

describe("test_nftables_apply_lock", () => {
  useGuest();

  beforeAll(async () => {
    const r = await exec("mktemp -d");
    TMPDIR = r.stdout.trim();
    await exec(`
      mkdir -p /tmp/singbox-ui
      mkdir -p '${TMPDIR}/bin'
      cat >'${TMPDIR}/bin/nft' <<'EOF'
#!/bin/sh
if [ "$1" = "-f" ]; then sleep 1; cat "$2" >/dev/null; exit 0; fi
exit 0
EOF
      chmod +x '${TMPDIR}/bin/nft'
      mkdir -p '${TMPDIR}/uci'
      printf '%s' '${UCI_CONFIG}' >'${TMPDIR}/uci/singbox-ui'
    `);
  });

  afterAll(async () => {
    if (TMPDIR) {
      await exec(`rm -rf '${TMPDIR}'; rm -rf /tmp/singbox-ui/.apply.lock`);
    }
  });

  it("S1-4: two concurrent applies serialize (one runs, one skipped), lock released", async () => {
    await exec("rm -rf /tmp/singbox-ui/.apply.lock");

    const r = await exec(`
      ${runApplyFn(TMPDIR)}
      run_apply '${TMPDIR}/a.err' &
      p1=$!
      run_apply '${TMPDIR}/b.err' &
      p2=$!
      if wait "$p1"; then rc1=0; else rc1=$?; fi
      if wait "$p2"; then rc2=0; else rc2=$?; fi
      [ "$rc1" -lt 128 ] && [ "$rc2" -lt 128 ] \
        || { echo "CRASH rc1=$rc1 rc2=$rc2"; cat '${TMPDIR}/a.err' '${TMPDIR}/b.err'; exit 1; }
      total=$(( rc1 + rc2 ))
      [ "$total" -eq 1 ] \
        || { echo "BOTH_SAME rc1=$rc1 rc2=$rc2"; cat '${TMPDIR}/a.err' '${TMPDIR}/b.err'; exit 1; }
      [ ! -e /tmp/singbox-ui/.apply.lock ] || { echo "LOCK_LEFT"; exit 1; }
      echo "OK"
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("S1-4: a pre-existing fresh lock with a live owner makes apply refuse", async () => {
    await exec("rm -rf /tmp/singbox-ui/.apply.lock");
    await exec(`
      mkdir -p /tmp/singbox-ui/.apply.lock
      echo $$ > /tmp/singbox-ui/.apply.lock/owner
    `);

    const r = await exec(`
      ${runApplyFn(TMPDIR)}
      rc=0
      run_apply '${TMPDIR}/held.err' || rc=$?
      rm -rf /tmp/singbox-ui/.apply.lock
      echo "$rc"
    `);
    expect(r.exitCode).toBe(0);
    const rc = parseInt(r.stdout.trim(), 10);
    expect(rc).toBeGreaterThan(0);
    expect(rc).toBeLessThan(128);
  });

  it("SEC-3: owner-less lock past grace period is reclaimed (not TTL-bound)", async () => {
    await exec("rm -rf /tmp/singbox-ui/.apply.lock");
    // Backdate ~30s past grace (5s) but under TTL (60s).
    // BusyBox date supports `date -d @<epoch>` for epoch conversion.
    await exec(`
      mkdir -p /tmp/singbox-ui/.apply.lock
      ts30=$(( $(date +%s) - 30 ))
      ts_fmt=$(date -d "@$ts30" '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202001010000')
      touch -t "$ts_fmt" /tmp/singbox-ui/.apply.lock
    `);

    const r = await exec(`
      ${runApplyFn(TMPDIR)}
      rc=0
      run_apply '${TMPDIR}/sec3.err' || rc=$?
      echo "$rc"
      [ -e /tmp/singbox-ui/.apply.lock ] && echo "LOCK_REMAINED" || echo "LOCK_GONE"
    `);
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.trim().split("\n");
    expect(parseInt(lines[0], 10)).toBe(0);   // apply succeeded (reclaimed)
    expect(lines[1]).toBe("LOCK_GONE");        // released after use
  });

  it("SEC-3: fresh owner-less lock (inside grace) must NOT be stolen", async () => {
    await exec("rm -rf /tmp/singbox-ui/.apply.lock");
    await exec("mkdir -p /tmp/singbox-ui/.apply.lock");

    const r = await exec(`
      ${runApplyFn(TMPDIR)}
      rc=0
      run_apply '${TMPDIR}/grace.err' || rc=$?
      rm -rf /tmp/singbox-ui/.apply.lock
      echo "$rc"
    `);
    expect(r.exitCode).toBe(0);
    const rc = parseInt(r.stdout.trim(), 10);
    // Must refuse — grace window closes the two-winners race
    expect(rc).toBeGreaterThan(0);
  });

  it("S5.1/10.3: stale (>60s) lock is reclaimed; apply succeeds and frees it", async () => {
    await exec("rm -rf /tmp/singbox-ui/.apply.lock");
    await exec(`
      mkdir -p /tmp/singbox-ui/.apply.lock
      touch -t 202001010000 /tmp/singbox-ui/.apply.lock
    `);

    const r = await exec(`
      ${runApplyFn(TMPDIR)}
      rc=0
      run_apply '${TMPDIR}/stale.err' || rc=$?
      echo "$rc"
      [ -e /tmp/singbox-ui/.apply.lock ] && echo "LOCK_REMAINED" || echo "LOCK_GONE"
    `);
    expect(r.exitCode).toBe(0);
    const lines = r.stdout.trim().split("\n");
    expect(parseInt(lines[0], 10)).toBe(0);  // apply succeeded
    expect(lines[1]).toBe("LOCK_GONE");      // lock released
  });
});
