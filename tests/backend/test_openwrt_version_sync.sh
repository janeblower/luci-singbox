#!/bin/sh
# tests/backend/test_openwrt_version_sync.sh
# Single-source-of-truth guard: every OpenWrt version reference across the repo
# must equal tests/docker/openwrt-version.txt. Catches the drift documented in
# the audit (version duplicated across 5+ files). Files that legitimately keep
# an inline literal (build-time, can't read a file) are asserted EQUAL to the
# canonical version -- not removed.
set -eu
cd "$(dirname "$0")/../.."
fail() { echo "FAIL: $1" >&2; exit 1; }

VF=tests/docker/openwrt-version.txt
[ -f "$VF" ] || fail "$VF missing"
VER=$(tr -d '[:space:]' < "$VF")
[ -n "$VER" ] || fail "version file empty"

# Files that reference an OpenWrt version literal and MUST match $VER.
# (Dockerfile itself is excluded -- it now interpolates the ARG, verified by
# tests/cross/test_openwrt_version_file.sh.)
CHECK="
.github/workflows/build.yml
.github/workflows/pages.yml
.github/workflows/test-image.yml
scripts/build-apk.sh
tests/browser-container/Dockerfile
tests/browser-container/entrypoint.sh
"

# Enumerate every OpenWrt release-version-looking token (X.Y.Z) that appears in
# an openwrt download URL or an openwrt rootfs tag in these files; each MUST be
# $VER. We scope to lines mentioning openwrt to avoid matching unrelated
# versions (bun, action SHAs, etc.). The SDK URL also carries the GCC toolchain
# version (e.g. gcc-14.3.0_musl) -- that is NOT an OpenWrt version, so tokens
# immediately preceded by "gcc-" are excluded before comparison.
for f in $CHECK; do
	[ -f "$f" ] || fail "$f missing (CHECK list stale)"
	# Pull version tokens from openwrt-related lines, dropping the gcc- one.
	bad=$(grep -E 'openwrt' "$f" \
		| grep -oE '[A-Za-z._/-]*[0-9]+\.[0-9]+\.[0-9]+' \
		| grep -vE 'gcc-[0-9]' \
		| grep -oE '[0-9]+\.[0-9]+\.[0-9]+' \
		| grep -vxF "$VER" || true)
	if [ -n "$bad" ]; then
		fail "$f references OpenWrt version(s) [$bad] != $VER (update or read from $VF)"
	fi
done

echo "OK ($VER)"
