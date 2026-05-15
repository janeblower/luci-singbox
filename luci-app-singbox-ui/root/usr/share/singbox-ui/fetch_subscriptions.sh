#!/bin/sh
# Resolve `proxy_type=subscription` outbounds: download the URL, extract proxy
# URLs (all of them, one per line) into /tmp/singbox-ui/sub_<section>.txt.
# Called by /etc/init.d/singbox-ui before generate.uc.
#
# NB: no `set -e` here. `uci -q get` of a missing option returns 1, which
# under `set -e` propagates through `var=$(uci -q get …)` and silently kills
# the script — taking down all subsequent sections with it. Same lesson as
# fetch_rulesets.sh.

TMPDIR=/tmp/singbox-ui
mkdir -p "$TMPDIR"

uci_get_or_empty() {
	uci -q get "$1" 2>/dev/null || printf ''
}

fetch_one() {
	name="$1"
	url="$2"
	update_via="$3"
	out="$TMPDIR/sub_${name}.txt"

	case "$update_via" in
	direct|"")
		raw=$(curl -sfL --max-time 15 "$url") || raw=""
		;;
	*)
		iface=$(uci_get_or_empty "singbox-ui.${update_via}.interface")
		if [ -n "$iface" ]; then
			raw=$(curl -sfL --max-time 15 --interface "$iface" "$url") || raw=""
		else
			echo "fetch_subscriptions: outbound '$update_via' has no interface" >&2
			return 1
		fi
		;;
	esac

	if [ -z "$raw" ]; then
		echo "fetch_subscriptions: empty/failed response for $name ($url)" >&2
		return 1
	fi

	decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null) || decoded=""
	[ -z "$decoded" ] && decoded="$raw"

	urls=$(printf '%s\n' "$decoded" | grep -E '^[a-z][a-z0-9+.-]*://') || urls=""
	if [ -z "$urls" ]; then
		echo "fetch_subscriptions: no valid proxy URL in response for $name" >&2
		return 1
	fi

	printf '%s\n' "$urls" > "$out"
	count=$(printf '%s\n' "$urls" | wc -l)
	echo "fetch_subscriptions: $name -> $out ($count urls)"
}

sections=$(uci show singbox-ui 2>/dev/null \
	| grep -E "^singbox-ui\.[^.]+\.proxy_type='subscription'" \
	| sed -E "s/^singbox-ui\.([^.]+)\.proxy_type=.*/\1/")

if [ -z "$sections" ]; then
	echo "fetch_subscriptions: no subscription outbounds configured" >&2
	exit 0
fi

for section in $sections; do
	enabled=$(uci_get_or_empty "singbox-ui.${section}.enabled")
	# Treat missing `enabled` as enabled (matches LuCI form default '1').
	if [ "$enabled" = "0" ]; then
		echo "fetch_subscriptions: $section disabled, skipping" >&2
		continue
	fi
	sub_url=$(uci_get_or_empty "singbox-ui.${section}.sub_url")
	sub_via=$(uci_get_or_empty "singbox-ui.${section}.sub_update_via")
	if [ -z "$sub_url" ]; then
		echo "fetch_subscriptions: $section has no sub_url, skipping" >&2
		continue
	fi
	fetch_one "$section" "$sub_url" "$sub_via" || true
done

exit 0
