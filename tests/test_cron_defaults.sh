#!/bin/sh
# tests/test_cron_defaults.sh
# The uci-defaults cron installer is idempotent: adds exactly one singbox-ui
# refresh line to the crontab and never duplicates it on re-run.
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
SCRIPT="$PWD/${SB_BACKEND_ROOT}/etc/uci-defaults/91-singbox-ui-cron"
[ -f "$SCRIPT" ] || { echo "FAIL: cron uci-defaults missing"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/crontabs"
run() { env SINGBOX_CRONTAB="$TMP/crontabs/root" SINGBOX_CRON_RELOAD="true" sh "$SCRIPT"; }

# Seed BOTH legacy forms: the old subs-only token line (91) and the old
# combined line (99). Both must be migrated away.
printf '%s\n%s\n%s\n' \
	'0 0 * * * /bin/true' \
	'*/15 * * * * /usr/bin/ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/subscription.uc refresh subscriptions' \
	'*/30 * * * * /usr/bin/ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/subscription.uc refresh all >/dev/null 2>&1' \
	> "$TMP/crontabs/root"

run; run   # twice — idempotent + migrating

legacy=$(grep -cE 'refresh subscriptions|refresh all' "$TMP/crontabs/root" 2>/dev/null || true)
[ "$legacy" = "0" ] || { echo "FAIL: legacy cron line(s) not migrated"; cat "$TMP/crontabs/root"; exit 1; }
subs=$(grep -c 'subscription.uc refresh$' "$TMP/crontabs/root" 2>/dev/null || true)
[ "$subs" = "1" ] || { echo "FAIL: expected exactly 1 subscription.uc cron line, got $subs"; cat "$TMP/crontabs/root"; exit 1; }
rs=$(grep -c 'nft-rulesets.uc refresh$' "$TMP/crontabs/root" 2>/dev/null || true)
[ "$rs" = "1" ] || { echo "FAIL: expected exactly 1 nft-rulesets.uc cron line, got $rs"; cat "$TMP/crontabs/root"; exit 1; }
unrelated=$(grep -c '/bin/true' "$TMP/crontabs/root" 2>/dev/null || true)
[ "$unrelated" = "1" ] || { echo "FAIL: unrelated cron line was clobbered"; cat "$TMP/crontabs/root"; exit 1; }

# Regression guard: 99-luci-singbox-ui must NOT touch the crontab (cron ownership
# consolidated into 91). A re-introduced cron block in 99 would re-create the
# conflict the split was meant to remove.
NINETYNINE="$PWD/${SB_BACKEND_ROOT}/etc/uci-defaults/99-luci-singbox-ui"
if grep -qE 'crontab|CRON_LINE|CRON_FILE' "$NINETYNINE"; then
	echo "FAIL: 99-luci-singbox-ui still manipulates the crontab (cron must live only in 91)"; exit 1
fi

echo "PASS: cron installs both entry-points, migrates legacy lines, 99 owns no cron"
