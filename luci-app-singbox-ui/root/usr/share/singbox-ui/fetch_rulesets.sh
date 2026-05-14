#!/bin/sh
# Download (or copy) and decompile rule-sets with nft_rules=1 to JSON caches at
# /tmp/singbox-ui/rs_<section>.json. Called by /etc/init.d/singbox-ui before
# nftables.sh apply.
#
# NB: no `set -e` here. `uci -q get` of a missing UCI option returns 1 even
# with -q (the flag only suppresses the error message). Under `set -e` a
# section that lacks e.g. an explicit `enabled` field would silently kill
# the whole script, dropping all subsequent rule-sets.

TMPDIR=/tmp/singbox-ui
SINGBOX=${SINGBOX:-/usr/bin/sing-box}
mkdir -p "$TMPDIR"

# uci_get_or_empty <singbox-ui.section.option>
# Returns the value or empty string, never errors.
uci_get_or_empty() {
	uci -q get "$1" 2>/dev/null || printf ''
}

fetch_ruleset() {
	name="$1"
	rs_type="$2"
	src="$3"
	fmt="$4"
	raw="$TMPDIR/rs_${name}.raw"
	out="$TMPDIR/rs_${name}.json"

	case "$rs_type" in
	remote)
		if ! curl -sf --max-time 30 -o "$raw" "$src" 2>/dev/null; then
			echo "fetch_rulesets: download failed: $src" >&2
			return 1
		fi
		;;
	local)
		if ! cp "$src" "$raw" 2>/dev/null; then
			echo "fetch_rulesets: cannot read: $src" >&2
			return 1
		fi
		;;
	*)
		echo "fetch_rulesets: unknown type '$rs_type' for $name" >&2
		return 1
		;;
	esac

	case "$fmt" in
	binary)
		# sing-box CLI: `decompile <input> -o <output>` (input is positional,
		# output requires the -o flag).
		if ! "$SINGBOX" rule-set decompile "$raw" -o "$out" 2>/dev/null; then
			echo "fetch_rulesets: decompile failed for $name" >&2
			return 1
		fi
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
		enabled=$(uci_get_or_empty "singbox-ui.${section}.enabled")
		# Treat missing `enabled` as enabled (matches LuCI form default '1').
		[ "$enabled" = "0" ] && continue

		rs_type=$(uci_get_or_empty "singbox-ui.${section}.type")
		fmt=$(uci_get_or_empty "singbox-ui.${section}.format")
		case "$rs_type" in
		remote) target=$(uci_get_or_empty "singbox-ui.${section}.url") ;;
		local)  target=$(uci_get_or_empty "singbox-ui.${section}.path") ;;
		*)      target="" ;;
		esac
		[ -z "$target" ] && continue
		fetch_ruleset "$section" "$rs_type" "$target" "$fmt"
	done

exit 0
