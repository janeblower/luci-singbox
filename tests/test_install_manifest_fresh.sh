#!/bin/sh
# tests/test_install_manifest_fresh.sh
# Verifies the per-package install manifests are in sync with what
# gen-manifest.sh would produce — catches drift between manual edits and
# auto-generation.
#
# Uses `cmp` instead of `diff` because the OpenWrt rootfs (Docker test env)
# ships BusyBox which provides cmp but not diff by default.
set -e
cd "$(dirname "$0")/.."

MANIFESTS="scripts/install-manifest-singbox-ui.txt scripts/install-manifest-luci-app-singbox-ui.txt"

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Snapshot the committed manifests, regenerate, compare each.
for m in $MANIFESTS; do cp "$m" "$tmpdir/$(basename "$m")"; done
sh scripts/gen-manifest.sh >/dev/null 2>&1

stale=0
for m in $MANIFESTS; do
	if ! cmp -s "$m" "$tmpdir/$(basename "$m")"; then
		echo "FAIL: $m is stale. Run: sh scripts/gen-manifest.sh"
		# Restore so the test itself doesn't dirty the working tree.
		cp "$tmpdir/$(basename "$m")" "$m"
		stale=1
	fi
done
[ "$stale" -eq 0 ] || exit 1
echo "PASS: install manifests are fresh"

# D4.5: plugin scaffolding invariant. The backend manifest must contain
# exactly ONE file under lib/plugins/ — the registry. Any additional file
# would mean a Phase D plugin shipped that wasn't sanctioned by spec.
BE=scripts/install-manifest-singbox-ui.txt
plugin_count=$(grep -c '^root/usr/share/singbox-ui/lib/plugins/' "$BE")
if [ "$plugin_count" -ne 1 ]; then
	echo "FAIL: expected 1 file under lib/plugins/ in manifest, found $plugin_count"
	exit 1
fi
if ! grep -q '^root/usr/share/singbox-ui/lib/plugins/registry\.uc' "$BE"; then
	echo "FAIL: lib/plugins/registry.uc missing from manifest"
	exit 1
fi
echo "PASS: lib/plugins invariant (exactly registry.uc)"
