#!/bin/sh
# awg-provision.sh — Self-provision AmneziaWG kernel module + tools on OpenWrt.
#
# 1. Detect OpenWrt version + target from /etc/openwrt_release (or ubus fallback).
# 2. Install the bundled AWG feed signing key (no network trust).
# 3. Idempotently add the AWG feed to /etc/apk/repositories.d/awg.list.
# 4. apk update + apk add ip-full kmod-amneziawg amneziawg-tools.
# 5. modprobe amneziawg (best-effort).
#
# Env seams for tests (all have production defaults):
#   APK_CMD         – apk binary (default: apk)
#   AWG_KEYS_DIR    – destination for the signing key (default: /etc/apk/keys)
#   AWG_REPOS_D     – directory for the feed repo file (default: /etc/apk/repositories.d)
#   AWG_KEY_SRC     – bundled signing key PEM shipped with this package
#   AWG_FEED_BASE   – base URL of the feed (default: slava-shchipunov GitHub Pages)
#   AWG_OWRT_RELEASE – path to /etc/openwrt_release (default: /etc/openwrt_release)

set -eu

APK_CMD="${APK_CMD:-apk}"
AWG_KEYS_DIR="${AWG_KEYS_DIR:-/etc/apk/keys}"
AWG_REPOS_D="${AWG_REPOS_D:-/etc/apk/repositories.d}"
AWG_KEY_SRC="${AWG_KEY_SRC:-/usr/share/singbox-ui/awg-openwrt-feed.pem}"
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

# ── 3. Install the AWG feed signing key (shipped in this package) ───────────
#
# The key is INSTALLED FROM DISK, not downloaded. apk-tools 3 trusts a key in
# /etc/apk/keys system-wide, by fingerprint, for every repository — so fetching
# one over the network and trusting whatever came back (no pin, no checksum, no
# validation) handed a permanent signing anchor to whoever could answer that URL
# or MITM it. Shipping the key in the package means it is reviewed and updated
# the same way as the rest of the code, and provisioning needs no trust in the
# network at all.

if [ ! -f "$AWG_KEY_SRC" ]; then
	echo "awg-provision: ERROR: bundled feed key missing at $AWG_KEY_SRC" >&2
	exit 1
fi
if ! grep -q '^-----BEGIN PUBLIC KEY-----$' "$AWG_KEY_SRC"; then
	echo "awg-provision: ERROR: bundled feed key is not a PEM public key" >&2
	exit 1
fi

mkdir -p "$AWG_KEYS_DIR"
cp "$AWG_KEY_SRC" "$AWG_KEYS_DIR/awg-openwrt-feed.pem"
chmod 0644 "$AWG_KEYS_DIR/awg-openwrt-feed.pem"
echo "awg-provision: key installed to $AWG_KEYS_DIR/awg-openwrt-feed.pem"

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
