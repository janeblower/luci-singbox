#!/bin/sh
# tests/test_install_lists_match.sh
#
# Architectural invariant: scripts/install-manifest.txt is the SINGLE
# source of truth for the install file set. Both the SDK Makefile and
# scripts/build-apk.sh must consume it. Drift between the two builders
# was the original failure mode (C2.3.1).
#
# This test asserts:
#   1. The manifest file exists.
#   2. Both builders reference it (i.e. neither has slipped back to
#      hardcoded install lines).
#   3. Every (non-comment) row is a 3-field TSV (src, dst, mode).
#   4. Every src listed exists in the source tree.
#   5. Every mode is one of bin|conf|data.
#   6. Every file under luci-app-singbox-ui/{root,htdocs} is covered by
#      the manifest (catches the "added a new file but forgot to ship
#      it" footgun).
set -e
cd "$(dirname "$0")/.."

MANIFEST="scripts/install-manifest.txt"
MAKEFILE="luci-app-singbox-ui/Makefile"
BUILDSH="scripts/build-apk.sh"

[ -f "$MANIFEST" ] || { echo "FAIL: $MANIFEST missing"; exit 1; }
[ -f "$MAKEFILE" ] || { echo "FAIL: $MAKEFILE missing"; exit 1; }
[ -f "$BUILDSH" ]  || { echo "FAIL: $BUILDSH missing";  exit 1; }

grep -q 'install-manifest.txt' "$MAKEFILE" \
    || { echo "FAIL: $MAKEFILE doesn't reference install-manifest.txt"; exit 1; }
grep -q 'install-manifest.txt' "$BUILDSH" \
    || { echo "FAIL: $BUILDSH doesn't reference install-manifest.txt"; exit 1; }
echo "  PASS: both builders reference single manifest"

TAB=$(printf '\t')
fail=0
listed_tmp=$(mktemp)
trap 'rm -f "$listed_tmp"' EXIT

while IFS="$TAB" read -r src dst mode rest; do
    # Strip leading whitespace from comment detection on src
    case "$src" in '#'*|'') continue ;; esac

    # Must be exactly 3 tab-separated fields — no extras, no missing.
    [ -n "$src" ] && [ -n "$dst" ] && [ -n "$mode" ] && [ -z "$rest" ] \
        || { echo "FAIL: not a 3-field TSV row: src='$src' dst='$dst' mode='$mode' rest='$rest'"; fail=1; continue; }

    if [ ! -f "luci-app-singbox-ui/$src" ]; then
        echo "FAIL: manifest src missing in source tree: $src"
        fail=1
    fi

    case "$mode" in
        bin|conf|data) ;;
        *) echo "FAIL: invalid mode '$mode' for $src"; fail=1 ;;
    esac

    printf '%s\n' "$src" >> "$listed_tmp"
done < "$MANIFEST"

if [ $fail -eq 0 ]; then
    echo "  PASS: all manifest entries valid (src exists, mode in {bin,conf,data})"
fi

# Coverage: every file under root/ and htdocs/ must be listed. Catches
# the C1-style regression where someone adds lib/scrub.uc but forgets to
# add it to the install set. Implemented with awk (BusyBox-portable —
# `comm` isn't available in the OpenWrt rootfs Docker image).
tree_tmp=$(mktemp)
missing_tmp=$(mktemp)
trap 'rm -f "$listed_tmp" "$tree_tmp" "$missing_tmp"' EXIT

find luci-app-singbox-ui/root luci-app-singbox-ui/htdocs -type f \
    | sed 's#^luci-app-singbox-ui/##' \
    | LC_ALL=C sort > "$tree_tmp"

# Files in $tree_tmp but NOT in $listed_tmp = uncovered.
awk 'NR==FNR {listed[$0]=1; next} !($0 in listed)' \
    "$listed_tmp" "$tree_tmp" > "$missing_tmp"
if [ -s "$missing_tmp" ]; then
    echo "FAIL: files in source tree not listed in $MANIFEST:"
    sed 's/^/    /' "$missing_tmp"
    fail=1
else
    echo "  PASS: every source-tree file is covered by the manifest"
fi

if [ $fail -eq 0 ]; then
    echo "OK"
    exit 0
fi
exit 1
