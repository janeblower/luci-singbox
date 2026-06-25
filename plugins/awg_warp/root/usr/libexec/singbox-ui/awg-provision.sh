#!/bin/sh
# awg-provision.sh — Self-provision AmneziaWG kernel module + tools on OpenWrt.
#
# 1. Detect OpenWrt version + target from /etc/openwrt_release (or ubus fallback).
# 2. Fetch the AWG feed signing key (wget).
# 3. Idempotently add the AWG feed to /etc/apk/repositories.d/awg.list.
# 4. apk update + apk add ip-full kmod-amneziawg amneziawg-tools.
# 5. modprobe amneziawg (best-effort).
#
# Env seams for tests (all have production defaults):
#   APK_CMD         – apk binary (default: apk)
#   WGET_CMD        – wget binary (default: wget)
#   AWG_KEYS_DIR    – destination for the signing key (default: /etc/apk/keys)
#   AWG_REPOS_D     – directory for the feed repo file (default: /etc/apk/repositories.d)
#   AWG_KEY_URL     – URL of the signing key PEM (default: slava-shchipunov GitHub Pages)
#   AWG_FEED_BASE   – base URL of the feed (default: slava-shchipunov GitHub Pages)
#   AWG_OWRT_RELEASE – path to /etc/openwrt_release (default: /etc/openwrt_release)

set -eu

APK_CMD="${APK_CMD:-apk}"
WGET_CMD="${WGET_CMD:-wget}"
AWG_KEYS_DIR="${AWG_KEYS_DIR:-/etc/apk/keys}"
AWG_REPOS_D="${AWG_REPOS_D:-/etc/apk/repositories.d}"
AWG_KEY_URL="${AWG_KEY_URL:-https://slava-shchipunov.github.io/awg-openwrt/keys/awg-openwrt-feed.pem}"
AWG_FEED_BASE="${AWG_FEED_BASE:-https://slava-shchipunov.github.io/awg-openwrt}"
AWG_OWRT_RELEASE="${AWG_OWRT_RELEASE:-/etc/openwrt_release}"

# ── 1. Detect version + target ───────────────────────────────────────────────

owrt_version=""
owrt_target=""

if [ -f "$AWG_OWRT_RELEASE" ]; then
	# Source only the two variables we need; do NOT eval the whole file.
	owrt_version=$(grep '^DISTRIB_RELEASE=' "$AWG_OWRT_RELEASE" \
		| sed "s/^DISTRIB_RELEASE=['\"]//;s/['\"]$//" | head -n 1)
	owrt_target=$(grep '^DISTRIB_TARGET=' "$AWG_OWRT_RELEASE" \
		| sed "s/^DISTRIB_TARGET=['\"]//;s/['\"]$//" | head -n 1)
fi

# Fallback: ask ubus (available in OpenWrt when the file is absent).
if [ -z "$owrt_version" ] || [ -z "$owrt_target" ]; then
	board_json=$(ubus call system board 2>/dev/null || true)
	if [ -n "$board_json" ]; then
		# Parse release.version and release.target using grep + sed (no jq on OpenWrt).
		_v=$(printf '%s' "$board_json" | grep -o '"version":"[^"]*"' \
			| sed 's/"version":"//;s/"$//' | head -n 1)
		_t=$(printf '%s' "$board_json" | grep -o '"target":"[^"]*"' \
			| sed 's/"target":"//;s/"$//' | head -n 1)
		[ -z "$owrt_version" ] && owrt_version="$_v"
		[ -z "$owrt_target" ]  && owrt_target="$_t"
	fi
fi

# ── 2. Validate version + target (defense-in-depth) ─────────────────────────
# Version: digits and dots only (e.g. 25.12.4).
# Target:  <subtarget>/<arch>, each component: lowercase alnum + "_-", min 1 char.

if ! printf '%s' "$owrt_version" | grep -qE '^[0-9.]+$'; then
	echo "awg-provision: ERROR: invalid OpenWrt version '$owrt_version' — aborting" >&2
	exit 1
fi

if ! printf '%s' "$owrt_target" | grep -qE '^[a-z0-9][a-z0-9_-]*/[a-z0-9][a-z0-9_-]*$'; then
	echo "awg-provision: ERROR: invalid OpenWrt target '$owrt_target' — aborting" >&2
	exit 1
fi

# ── 3. Fetch the AWG feed signing key ───────────────────────────────────────

mkdir -p "$AWG_KEYS_DIR"
echo "awg-provision: fetching feed key from $AWG_KEY_URL"
if ! "$WGET_CMD" -O "$AWG_KEYS_DIR/awg-openwrt-feed.pem" "$AWG_KEY_URL"; then
	echo "awg-provision: ERROR: failed to fetch signing key" >&2
	exit 1
fi
echo "awg-provision: key written to $AWG_KEYS_DIR/awg-openwrt-feed.pem"

# ── 4. Idempotently add the AWG feed ────────────────────────────────────────

feed_url="${AWG_FEED_BASE}/${owrt_version}/${owrt_target}/packages.adb"
mkdir -p "$AWG_REPOS_D"
repo_file="$AWG_REPOS_D/awg.list"

if grep -qF "$feed_url" "$repo_file" 2>/dev/null; then
	echo "awg-provision: feed already in $repo_file (idempotent)"
else
	printf '%s\n' "$feed_url" >> "$repo_file"
	echo "awg-provision: added feed $feed_url to $repo_file"
fi

# ── 5. apk update + add packages ────────────────────────────────────────────

echo "awg-provision: running $APK_CMD update"
"$APK_CMD" update

echo "awg-provision: installing ip-full kmod-amneziawg amneziawg-tools"
if ! "$APK_CMD" add ip-full kmod-amneziawg amneziawg-tools; then
	echo "awg-provision: ERROR: apk add failed" >&2
	exit 1
fi

# ── 6. Load the kernel module (best-effort) ──────────────────────────────────

modprobe amneziawg 2>/dev/null || true

echo "awg-provision: ok"
