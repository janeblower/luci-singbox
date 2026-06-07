#!/bin/sh
# tests/test_install_manifest_fresh.sh
# Verifies scripts/install-manifest.txt is in sync with what gen-manifest.sh
# would produce — catches drift between manual edits and auto-generation.
#
# Uses `cmp` instead of `diff` because the OpenWrt rootfs (Docker test env)
# ships BusyBox which provides cmp but not diff by default.
set -e
cd "$(dirname "$0")/.."

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cp scripts/install-manifest.txt "$tmp"
sh scripts/gen-manifest.sh >/dev/null 2>&1

if ! cmp -s scripts/install-manifest.txt "$tmp"; then
	echo "FAIL: install-manifest.txt is stale. Run: sh scripts/gen-manifest.sh"
	# Restore so the test itself doesn't dirty the working tree.
	cp "$tmp" scripts/install-manifest.txt
	exit 1
fi
echo "PASS: install-manifest.txt is fresh"
