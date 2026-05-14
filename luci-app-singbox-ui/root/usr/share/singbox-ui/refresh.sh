#!/bin/sh
# Refresh subscriptions and/or rulesets, respecting per-section update intervals.
# Called by cron (*/30) and by the rpcd `refresh` method.
#
# Usage: refresh.sh {subscriptions|rulesets|all} [force]
#   - Without `force`, only entries older than their *_interval are refetched.
#   - With `force`, every entry is refetched unconditionally.
#
# Exits 0 always; per-entry failures are logged to stderr.

TMPDIR=/tmp/singbox-ui
mkdir -p "$TMPDIR"

WHAT="${1:-all}"
FORCE="${2:-}"

# Returns 0 if file is older than interval seconds (or missing); 1 otherwise.
is_stale() {
	file="$1"
	interval="$2"
	[ "$FORCE" = "force" ] && return 0
	[ -f "$file" ] || return 0
	[ -z "$interval" ] && return 0
	[ "$interval" -eq 0 ] 2>/dev/null && return 0
	now=$(date +%s)
	mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
	age=$((now - mtime))
	[ "$age" -ge "$interval" ]
}

refreshed_any=0
mark_refreshed() { refreshed_any=1; }

if [ "$WHAT" = "subscriptions" ] || [ "$WHAT" = "all" ]; then
	stale=0
	for section in $(uci show singbox-ui 2>/dev/null \
		| grep -E "^singbox-ui\.[^.]+\.proxy_type='subscription'" \
		| sed -E "s/^singbox-ui\.([^.]+)\.proxy_type=.*/\1/"); do
		enabled=$(uci -q get "singbox-ui.${section}.enabled")
		[ "$enabled" = "0" ] && continue
		interval=$(uci -q get "singbox-ui.${section}.sub_interval")
		interval=${interval:-3600}
		if is_stale "$TMPDIR/sub_${section}.txt" "$interval"; then
			stale=1
		fi
	done
	if [ "$stale" = "1" ]; then
		/usr/share/singbox-ui/fetch_subscriptions.sh && mark_refreshed
	fi
fi

if [ "$WHAT" = "rulesets" ] || [ "$WHAT" = "all" ]; then
	stale=0
	for section in $(uci show singbox-ui 2>/dev/null \
		| grep -E "^singbox-ui\.[^.]+\.nft_rules='1'" \
		| sed -E "s/^singbox-ui\.([^.]+)\.nft_rules=.*/\1/"); do
		enabled=$(uci -q get "singbox-ui.${section}.enabled")
		[ "$enabled" = "0" ] && continue
		interval=$(uci -q get "singbox-ui.${section}.update_interval")
		interval=${interval:-86400}
		if is_stale "$TMPDIR/rs_${section}.json" "$interval"; then
			stale=1
		fi
	done
	if [ "$stale" = "1" ]; then
		/usr/share/singbox-ui/fetch_rulesets.sh && mark_refreshed
	fi
fi

if [ "$refreshed_any" = "1" ] && [ -x /etc/init.d/singbox-ui ]; then
	/etc/init.d/singbox-ui reload >/dev/null 2>&1 || true
fi

exit 0
