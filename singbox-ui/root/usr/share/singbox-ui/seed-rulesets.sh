#!/bin/sh
# Seed the built-in rule-sets from itdoginfo/allow-domains.
#
# They are ordinary `ruleset` sections carrying `option builtin '1'`, which the
# UI renders read-only (no Edit/Delete) and the backend gates on the
# singbox-ui.main.default_rulesets master switch (helpers.ruleset_active).
#
# WHY THIS IS A PERSISTENT SCRIPT AND NOT JUST A uci-defaults ENTRY:
# uci-defaults runs exactly once — OpenWrt deletes the file after a successful
# first boot. So "delete /etc/config/singbox-ui, drop in a fresh one, reboot"
# left the box with ZERO rule-sets, forever: the seed had already run and been
# removed. init.d start_service now calls this on every start, so the built-ins
# self-heal. The uci-defaults entry still calls it too, so a first install seeds
# them before the service ever starts.
#
# The URLs point at the release channel's `latest` alias, so a new upstream
# release is picked up without touching the config; sing-box re-fetches each
# .srs on its own update_interval.
#
# They ship ENABLED, which costs nothing: an enabled rule-set nobody references
# is neither emitted into the config (ruleset.uc only builds referenced tags) nor
# downloaded (nft-rulesets.uc only fetches nft_rules=1). Shipping them disabled
# was a footgun — point a route rule at a disabled set and route.uc drops the
# whole rule (the catch-all guard kills the now-matcher-less rule), so "I
# referenced youtube and nothing happens" with only a warn in logread.
#
# IDEMPOTENT AND WEAR-SAFE: a section that already exists is left alone (a user
# who turned `porn` OFF must not have it switched back on), and the commit only
# fires when something actually changed — a fully-seeded config produces no UCI
# write at all, so calling this on every boot does not churn flash. Honours the
# master switch: with default_rulesets=0 nothing is created.
#
# SINGBOX_UCI is a test/dev seam. The uci CLI does NOT honour UCI_CONFIG_DIR
# (only `-c <dir>`), so without it this script could only ever be exercised
# against the live /etc/config — which means it could not be tested at all, and
# scripts/dev-stand.sh could not replay it into a sandbox container.
# shellcheck disable=SC2086  # SINGBOX_UCI deliberately carries flags (-c <dir>)
UCI="${SINGBOX_UCI:-uci}"
uci_() { $UCI "$@"; }

BASE='https://github.com/itdoginfo/allow-domains/releases/latest/download'
INTERVAL='86400'

SETS='anime block cloudflare cloudfront digitalocean discord geoblock google_ai
      google_meet google_play hdrezka hetzner hodca meta news ovh porn roblox
      russia_inside russia_outside telegram tiktok twitter ukraine_inside youtube'

[ "$(uci_ -q get singbox-ui.main.default_rulesets)" = "0" ] && exit 0

# Track whether anything actually changed, so a no-op reconcile never rewrites
# /etc/config (flash-wear on real routers, and it would also churn the config
# the user is looking at). set_if() only writes when the value differs.
_changed=0
set_if() { # <path> <value>
	[ "$(uci_ -q get "$1")" = "$2" ] && return 0
	uci_ -q set "$1=$2"
	_changed=1
}

uci_ -q get singbox-ui.main >/dev/null || { uci_ -q set singbox-ui.main='singbox-ui'; _changed=1; }
set_if singbox-ui.main.default_rulesets '1'

for name in $SETS; do
	# Already present — this script ran on a previous install/boot, or the user
	# created a set with that name. Only stamp the builtin marker; never touch
	# enabled/url, those are theirs to own.
	if uci_ -q get "singbox-ui.$name" >/dev/null; then
		set_if "singbox-ui.$name.builtin" '1'
		continue
	fi
	uci_ -q set "singbox-ui.$name"='ruleset'
	uci_ -q set "singbox-ui.$name.builtin"='1'
	uci_ -q set "singbox-ui.$name.enabled"='1'
	uci_ -q set "singbox-ui.$name.type"='remote'
	uci_ -q set "singbox-ui.$name.url"="$BASE/$name.srs"
	uci_ -q set "singbox-ui.$name.nft_rules"='0'
	uci_ -q set "singbox-ui.$name.update_interval"="$INTERVAL"
	_changed=1
done

[ "$_changed" = "1" ] && uci_ -q commit singbox-ui
exit 0
