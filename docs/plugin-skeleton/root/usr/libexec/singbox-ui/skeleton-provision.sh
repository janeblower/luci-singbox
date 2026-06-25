#!/bin/sh
### skeleton-provision.sh — self-provision external feed components.
#
# This script is an OPTIONAL stub showing the self-provisioning pattern.
# Delete it if your plugin has no external runtime dependencies.
#
# How it works:
#   1. Detect the OpenWrt version + target from /etc/openwrt_release.
#   2. Fetch the feed signing key dynamically via wget (TOFU — the operator
#      accepts by clicking the "Install" button in the LuCI plugin tab).
#   3. Idempotently add the feed to its OWN /etc/apk/repositories.d/<name>.list
#      (grep -q guard prevents duplicate lines).
#   4. apk update + apk add the external components.
#
# The rpcd wrapper in init.uc runs this script and MUST suppress its stdout:
#   system(script + " >/dev/null")
# Only stderr propagates; the rpcd response is the JSON from printf("%J\n",...).
#
# Env seams (all have production defaults; override in tests):
#   APK_CMD          – apk binary            (default: apk)
#   WGET_CMD         – wget binary           (default: wget)
#   KEYS_DIR         – signing key directory (default: /etc/apk/keys)
#   REPOS_D          – repo list directory   (default: /etc/apk/repositories.d)
#   KEY_URL          – signing key PEM URL
#   FEED_BASE        – base URL of the feed  (arch/version injected at runtime)
#   OWRT_RELEASE     – path to /etc/openwrt_release

set -eu

APK_CMD="${APK_CMD:-apk}"
WGET_CMD="${WGET_CMD:-wget}"
KEYS_DIR="${KEYS_DIR:-/etc/apk/keys}"
REPOS_D="${REPOS_D:-/etc/apk/repositories.d}"
KEY_URL="${KEY_URL:-https://example.com/keys/skeleton-feed.pem}"
FEED_BASE="${FEED_BASE:-https://example.com/skeleton-feed}"
OWRT_RELEASE="${OWRT_RELEASE:-/etc/openwrt_release}"

# ── 1. Detect version + target ────────────────────────────────────────────────
if [ -r "$OWRT_RELEASE" ]; then
    # shellcheck source=/dev/null
    . "$OWRT_RELEASE"
    OWRT_VERSION="${DISTRIB_RELEASE:-}"
    OWRT_TARGET="${DISTRIB_TARGET:-}"
else
    echo "skeleton-provision: ERROR: cannot read $OWRT_RELEASE" >&2
    exit 1
fi

if [ -z "$OWRT_VERSION" ] || [ -z "$OWRT_TARGET" ]; then
    echo "skeleton-provision: ERROR: could not detect version or target" >&2
    exit 1
fi

# ── 2. Validate (defense-in-depth) ────────────────────────────────────────────
# Version: digits and dots only (e.g. 25.12.4).
# shellcheck disable=SC2254
case "$OWRT_VERSION" in
    *[!0-9.]*) echo "skeleton-provision: ERROR: unexpected version: $OWRT_VERSION" >&2; exit 1 ;;
esac

# ── 3. Fetch the feed signing key ─────────────────────────────────────────────
mkdir -p "$KEYS_DIR"
KEY_FILE="$KEYS_DIR/skeleton-feed.pem"
echo "skeleton-provision: fetching signing key from $KEY_URL"
"$WGET_CMD" -q -O "$KEY_FILE" "$KEY_URL"

# ── 4. Idempotently add the feed ──────────────────────────────────────────────
REPO_URL="$FEED_BASE/$OWRT_VERSION/$OWRT_TARGET"
REPO_FILE="$REPOS_D/skeleton.list"
mkdir -p "$REPOS_D"
if ! grep -qF "$REPO_URL" "$REPO_FILE" 2>/dev/null; then
    printf '%s\n' "$REPO_URL" >> "$REPO_FILE"
    echo "skeleton-provision: added feed $REPO_URL to $REPO_FILE"
else
    echo "skeleton-provision: feed already present in $REPO_FILE"
fi

# ── 5. apk update + install components ────────────────────────────────────────
echo "skeleton-provision: running $APK_CMD update"
"$APK_CMD" update

echo "skeleton-provision: installing skeleton-component"
if ! "$APK_CMD" add skeleton-component; then
    echo "skeleton-provision: ERROR: apk add failed" >&2
    exit 1
fi

echo "skeleton-provision: done"
