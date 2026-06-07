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

# D4.5: plugin scaffolding invariant. The production manifest must contain
# exactly ONE file under lib/plugins/ — the registry. Any additional file
# would mean a Phase D plugin shipped that wasn't sanctioned by spec.
plugin_count=$(grep -c '^root/usr/share/singbox-ui/lib/plugins/' scripts/install-manifest.txt)
if [ "$plugin_count" -ne 1 ]; then
	echo "FAIL: expected 1 file under lib/plugins/ in manifest, found $plugin_count"
	exit 1
fi
if ! grep -q '^root/usr/share/singbox-ui/lib/plugins/registry\.uc' scripts/install-manifest.txt; then
	echo "FAIL: lib/plugins/registry.uc missing from manifest"
	exit 1
fi
echo "PASS: lib/plugins invariant (exactly registry.uc)"
