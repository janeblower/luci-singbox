#!/bin/sh
# Download (or copy) and decompile rule-sets with nft_rules=1 to JSON caches at
# /tmp/singbox-ui/rs_<section>.json. Called by /etc/init.d/singbox-ui before
# nftables.sh apply.

set -e

TMPDIR=/tmp/singbox-ui
SINGBOX=${SINGBOX:-/usr/bin/sing-box}
mkdir -p "$TMPDIR"

fetch_ruleset() {
	name="$1"
	rs_type="$2"
	src="$3"
	fmt="$4"
	raw="$TMPDIR/rs_${name}.raw"
	out="$TMPDIR/rs_${name}.json"

	case "$rs_type" in
	remote)
		curl -sf --max-time 30 -o "$raw" "$src" 2>/dev/null \
			|| { echo "fetch_rulesets: download failed: $src" >&2; return 1; }
		;;
	local)
		cp "$src" "$raw" 2>/dev/null \
			|| { echo "fetch_rulesets: cannot read: $src" >&2; return 1; }
		;;
	*)
		echo "fetch_rulesets: unknown type '$rs_type' for $name" >&2
		return 1
		;;
	esac

	case "$fmt" in
	binary)
		"$SINGBOX" rule-set decompile "$raw" "$out" 2>/dev/null \
			|| { echo "fetch_rulesets: decompile failed for $name" >&2; return 1; }
		;;
	source)
		cp "$raw" "$out"
		;;
	*)
		echo "fetch_rulesets: unknown format '$fmt' for $name" >&2
		return 1
		;;
	esac

	echo "fetch_rulesets: $name -> $out"
}

uci show singbox-ui 2>/dev/null | \
	grep -E "^singbox-ui\.[^.]+\.nft_rules='1'" | \
	sed -E "s/^singbox-ui\.([^.]+)\.nft_rules=.*/\1/" | \
	while read -r section; do
		enabled=$(uci -q get "singbox-ui.${section}.enabled")
		[ "$enabled" = "0" ] && continue
		rs_type=$(uci -q get "singbox-ui.${section}.type")
		fmt=$(uci -q get "singbox-ui.${section}.format")
		case "$rs_type" in
		remote) target=$(uci -q get "singbox-ui.${section}.url") ;;
		local)  target=$(uci -q get "singbox-ui.${section}.path") ;;
		*)      target="" ;;
		esac
		[ -z "$target" ] && continue
		fetch_ruleset "$section" "$rs_type" "$target" "$fmt" || true
	done

exit 0
