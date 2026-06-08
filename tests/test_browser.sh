#!/bin/sh
# tests/test_browser.sh — Headless-Chrome integration tests against the live
# LuCI UI on the OpenWrt test VM ($VM_HOST, default 192.168.100.145).
#
# Each .mjs in tests/browser/ drives Chrome via Puppeteer and asserts UI
# behaviour. Snapshots /etc/config/singbox-ui before the run, restores it
# after, regardless of pass/fail.
#
# SKIPs cleanly when:
#   * node is missing
#   * puppeteer's Chrome binary is missing (run `npx puppeteer browsers install chrome` once)
#   * sshpass is missing
#   * the VM is unreachable on TCP/22
#
# Auto-deploys the worktree's luci-app-singbox-ui/ tree to the VM before
# running tests, so what you see is the code in git, not whatever was last
# manually copied.
set -eu
cd "$(dirname "$0")/.."

VM_HOST="${VM_HOST:-192.168.100.145}"
VM_USER="${VM_USER:-root}"
VM_PASS="${VM_PASS:-admin}"
BROWSER_DIR="tests/browser"

skip() { echo "SKIP test_browser: $1"; exit 0; }

command -v node >/dev/null 2>&1 || skip "node missing"
command -v sshpass >/dev/null 2>&1 || skip "sshpass missing (apt install sshpass)"

# Probe Chrome cache. Puppeteer downloads into ~/.cache/puppeteer.
ls "$HOME/.cache/puppeteer/chrome" >/dev/null 2>&1 \
    || skip "puppeteer Chrome missing (run: npx -y puppeteer browsers install chrome)"

# Probe VM reachability (TCP/22, 3s timeout).
nc -z -w3 "$VM_HOST" 22 2>/dev/null \
    || skip "VM $VM_HOST:22 unreachable"

# Probe LuCI auth.
authcheck=$(curl -sk -o /dev/null -w '%{http_code}' \
    --connect-timeout 3 --max-time 5 \
    "http://$VM_HOST/cgi-bin/luci" 2>/dev/null || echo "000")
[ "$authcheck" != "000" ] || skip "LuCI HTTP not responding on $VM_HOST"

# Install puppeteer for tests/browser (one-time per worktree).
if [ ! -d "$BROWSER_DIR/node_modules" ]; then
    echo "==> installing puppeteer (one-time)"
    ( cd "$BROWSER_DIR" && npm install --silent --no-audit --no-fund ) \
        || { echo "FAIL: npm install failed"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Snapshot UCI before any test mutates it.
# ---------------------------------------------------------------------------
SNAPSHOT="/tmp/singbox-ui.snap.$$"
echo "==> snapshot /etc/config/singbox-ui → $SNAPSHOT on VM"
sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no \
    "$VM_USER@$VM_HOST" "cp /etc/config/singbox-ui $SNAPSHOT" \
    || { echo "FAIL: snapshot copy failed"; exit 1; }

cleanup() {
    echo "==> restoring /etc/config/singbox-ui from snapshot"
    sshpass -p "$VM_PASS" ssh -o StrictHostKeyChecking=no \
        "$VM_USER@$VM_HOST" \
        "cp $SNAPSHOT /etc/config/singbox-ui && rm -f $SNAPSHOT && /etc/init.d/sing-box restart >/dev/null 2>&1 && /etc/init.d/rpcd reload >/dev/null 2>&1" \
        || echo "WARN: restore failed — UCI may be in test state"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Auto-deploy current branch (root/ + htdocs/) to the VM via two tar pipes.
# This is faster than a per-file loop and keeps the VM in sync with git.
# ---------------------------------------------------------------------------
echo "==> deploying worktree to $VM_HOST"
sshpass_ssh="sshpass -p $VM_PASS ssh -o StrictHostKeyChecking=no $VM_USER@$VM_HOST"
( cd luci-app-singbox-ui/root  && tar -cf - . ) | $sshpass_ssh "tar -xf - -C /"
( cd luci-app-singbox-ui/htdocs && tar -cf - . ) | $sshpass_ssh "tar -xf - -C /www/"
$sshpass_ssh "chmod +x /usr/libexec/rpcd/singbox-ui /usr/share/singbox-ui/*.uc 2>/dev/null; /etc/init.d/rpcd reload >/dev/null"

# ---------------------------------------------------------------------------
# Run each browser test in turn.
# ---------------------------------------------------------------------------
export VM_HOST VM_USER VM_PASS
fail=0
for t in "$BROWSER_DIR"/[0-9]*.mjs; do
    [ -e "$t" ] || continue
    echo
    echo "==> $t"
    if ! ( cd "$BROWSER_DIR" && node "$(basename "$t")" ); then
        echo "FAIL: $t"
        fail=1
    fi
done

[ "$fail" -eq 0 ] || exit 1
echo
echo "ALL PASS: test_browser"
