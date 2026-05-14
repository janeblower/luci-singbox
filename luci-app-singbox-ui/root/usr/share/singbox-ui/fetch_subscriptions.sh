#!/bin/sh
# Resolve `proxy_type=subscription` outbounds: download the URL, extract the
# first valid proxy URL, write it to /tmp/singbox-ui/sub_<section>.txt.
# Called by /etc/init.d/singbox-ui before generate.uc.

set -e

TMPDIR=/tmp/singbox-ui
mkdir -p "$TMPDIR"

fetch_one() {
	name="$1"
	url="$2"
	update_via="$3"
	out="$TMPDIR/sub_${name}.txt"

	case "$update_via" in
	direct|"")
		raw=$(curl -sf --max-time 15 "$url" 2>/dev/null) || raw=""
		;;
	*)
		iface=$(uci -q get "singbox-ui.${update_via}.interface")
		if [ -n "$iface" ]; then
			raw=$(curl -sf --max-time 15 --interface "$iface" "$url" 2>/dev/null) || raw=""
		else
			echo "fetch_subscriptions: outbound '$update_via' has no interface" >&2
			return 1
		fi
		;;
	esac

	[ -z "$raw" ] && { echo "fetch_subscriptions: empty response for $name" >&2; return 1; }

	decoded=$(printf '%s' "$raw" | base64 -d 2>/dev/null) || decoded=""
	[ -z "$decoded" ] && decoded="$raw"

	first_url=$(printf '%s\n' "$decoded" | grep -m1 '^[a-z][a-z0-9+.-]*://') || first_url=""
	[ -z "$first_url" ] && { echo "fetch_subscriptions: no valid proxy URL in response for $name" >&2; return 1; }

	printf '%s\n' "$first_url" > "$out"
	echo "fetch_subscriptions: $name -> $out"
}

uci show singbox-ui 2>/dev/null | \
	grep -E "^singbox-ui\.[^.]+\.proxy_type='subscription'" | \
	sed -E "s/^singbox-ui\.([^.]+)\.proxy_type=.*/\1/" | \
	while read -r section; do
		enabled=$(uci -q get "singbox-ui.${section}.enabled")
		[ "$enabled" = "0" ] && continue
		sub_url=$(uci -q get "singbox-ui.${section}.sub_url")
		sub_via=$(uci -q get "singbox-ui.${section}.sub_update_via")
		[ -z "$sub_url" ] && continue
		fetch_one "$section" "$sub_url" "$sub_via" || true
	done

exit 0
