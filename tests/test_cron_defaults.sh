#!/bin/sh
# tests/test_cron_defaults.sh
# The uci-defaults cron installer is idempotent: adds exactly one singbox-ui
# refresh line to the crontab and never duplicates it on re-run.
set -e
cd "$(dirname "$0")/.."
SCRIPT="$PWD/luci-singbox-ui/root/etc/uci-defaults/91-singbox-ui-cron"
[ -f "$SCRIPT" ] || { echo "FAIL: cron uci-defaults missing"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/crontabs"
run() { env SINGBOX_CRONTAB="$TMP/crontabs/root" SINGBOX_CRON_RELOAD="true" sh "$SCRIPT"; }
run; run    # twice
lines=$(grep -c 'subscription.uc refresh subscriptions' "$TMP/crontabs/root" 2>/dev/null || echo 0)
[ "$lines" = "1" ] || { echo "FAIL: expected 1 cron line, got $lines"; cat "$TMP/crontabs/root"; exit 1; }
echo "PASS: cron installer is idempotent (single refresh line)"
