#!/bin/sh
# tests/cross/test_openwrt_version_file.sh
# The single OpenWrt version source must exist and the Dockerfile must consume
# it via a build ARG (not a hardcoded literal in IMAGE_URL/IMAGE_FILE).
set -eu
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $1" >&2; exit 1; }

VF=tests/docker/openwrt-version.txt
[ -f "$VF" ] || fail "$VF missing (single version source)"
VER=$(tr -d '[:space:]' < "$VF")
case "$VER" in
	[0-9]*.[0-9]*.[0-9]*) : ;;
	*) fail "version file content '$VER' is not an X.Y.Z string" ;;
esac

DF=tests/docker/Dockerfile
grep -qE '^ARG OPENWRT_VERSION' "$DF" \
	|| fail "Dockerfile does not declare ARG OPENWRT_VERSION"
# IMAGE_URL/IMAGE_FILE must reference the ARG, not a bare 25.12.3 literal.
grep -qE 'IMAGE_URL=.*\$\{?OPENWRT_VERSION' "$DF" \
	|| fail "Dockerfile IMAGE_URL does not interpolate OPENWRT_VERSION"
grep -qE 'IMAGE_FILE=.*\$\{?OPENWRT_VERSION' "$DF" \
	|| fail "Dockerfile IMAGE_FILE does not interpolate OPENWRT_VERSION"
# No leftover hardcoded version in the URL/FILE ENV lines.
grep -nE '^ENV IMAGE_(URL|FILE)=' "$DF" | grep -q '25\.12\.3' \
	&& fail "Dockerfile IMAGE_URL/IMAGE_FILE still hardcodes 25.12.3"

echo "OK"
