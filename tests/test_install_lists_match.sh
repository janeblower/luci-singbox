#!/bin/sh
# tests/test_install_lists_match.sh
#
# Architectural invariant (three-way split): each package's install manifest is
# the SINGLE source of truth for that package's install file set. The package's
# buildroot Makefile AND scripts/build-apk.sh must both consume it. Drift
# between the two builders was the original failure mode (C2.3.1).
#
# Two file-set packages, two manifests, two source trees:
#   backend  singbox-ui/          -> scripts/install-manifest-singbox-ui.txt
#   frontend luci-app-singbox-ui/ -> scripts/install-manifest-luci-app-singbox-ui.txt
#
# For EACH package this test asserts:
#   1. The manifest file exists and is non-empty.
#   2. Both builders reference it (package Makefile's while-read loop +
#      scripts/build-apk.sh) — neither has slipped back to hardcoded install
#      lines.
#   3. Every (non-comment) row is a 3-field TSV (src, dst, mode).
#   4. Every src listed exists in that package's source tree.
#   5. Every mode is one of bin|conf|data.
#   6. Every shippable file under the package's source tree is covered by the
#      manifest (catches the "added a new file but forgot to ship it" footgun).
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."

BUILDSH="scripts/build-apk.sh"
[ -f "$BUILDSH" ] || { echo "FAIL: $BUILDSH missing"; exit 1; }

TAB=$(printf '\t')
fail=0

# check_pkg <label> <pkg-src-dir> <manifest> <makefile> <coverage-glob...>
#   coverage-glob = space-separated list of dirs (relative to repo root) whose
#   files must all appear in the manifest.
check_pkg() {
    label="$1"; src_dir="$2"; manifest="$3"; makefile="$4"; shift 4
    cov_dirs="$*"

    echo "== $label =="
    [ -f "$manifest" ] || { echo "FAIL: $manifest missing"; fail=1; return; }
    [ -s "$manifest" ] || { echo "FAIL: $manifest is empty"; fail=1; return; }
    [ -f "$makefile" ] || { echo "FAIL: $makefile missing"; fail=1; return; }

    man_base="$(basename "$manifest")"

    # Both builders must reference THIS package's manifest by name.
    grep -q "$man_base" "$makefile" \
        || { echo "FAIL: $makefile doesn't reference $man_base"; fail=1; }
    grep -q "$man_base" "$BUILDSH" \
        || { echo "FAIL: $BUILDSH doesn't reference $man_base"; fail=1; }
    # The Makefile must drive install from a manifest while-read loop, not
    # hardcoded install lines.
    grep -q 'while .*read .*src .*dst .*mode' "$makefile" \
        || { echo "FAIL: $makefile has no manifest-driven install loop"; fail=1; }
    echo "  PASS: both builders reference $man_base via a manifest-driven loop"

    listed_tmp=$(mktemp)

    while IFS="$TAB" read -r src dst mode rest; do
        case "$src" in '#'*|'') continue ;; esac

        # Exactly 3 tab-separated fields — no extras, no missing.
        [ -n "$src" ] && [ -n "$dst" ] && [ -n "$mode" ] && [ -z "$rest" ] \
            || { echo "FAIL: not a 3-field TSV row in $man_base: src='$src' dst='$dst' mode='$mode' rest='$rest'"; fail=1; continue; }

        if [ ! -f "$src_dir/$src" ]; then
            echo "FAIL: $man_base src missing in source tree: $src_dir/$src"
            fail=1
        fi

        case "$mode" in
            bin|conf|data) ;;
            *) echo "FAIL: invalid mode '$mode' for $src in $man_base"; fail=1 ;;
        esac

        printf '%s\n' "$src" >> "$listed_tmp"
    done < "$manifest"
    echo "  PASS: all $man_base entries valid (src exists, mode in {bin,conf,data})"

    # Coverage: every file under the coverage dirs must be listed.
    # (BusyBox-portable: awk, not comm.)
    tree_tmp=$(mktemp)
    missing_tmp=$(mktemp)
    # shellcheck disable=SC2086  # cov_dirs is an intentional multi-path list
    find $cov_dirs -type f \
        | sed "s#^$src_dir/##" \
        | LC_ALL=C sort > "$tree_tmp"

    awk 'NR==FNR {listed[$0]=1; next} !($0 in listed)' \
        "$listed_tmp" "$tree_tmp" > "$missing_tmp"
    if [ -s "$missing_tmp" ]; then
        echo "FAIL: files in $src_dir not listed in $man_base:"
        sed 's/^/    /' "$missing_tmp"
        fail=1
    else
        echo "  PASS: every shippable $label source-tree file is covered by $man_base"
    fi

    rm -f "$listed_tmp" "$tree_tmp" "$missing_tmp"
}

# Backend: ships everything under singbox-ui/root/.
check_pkg "backend (singbox-ui)" \
    "singbox-ui" \
    "scripts/install-manifest-singbox-ui.txt" \
    "singbox-ui/Makefile" \
    "singbox-ui/root"

# Frontend: ships htdocs (-> www) + root/ (menu.d, acl.d). po/ is compiled by
# po2lmo separately (not manifest-driven) so it's NOT a coverage dir.
check_pkg "frontend (luci-app-singbox-ui)" \
    "luci-app-singbox-ui" \
    "scripts/install-manifest-luci-app-singbox-ui.txt" \
    "luci-app-singbox-ui/Makefile" \
    "luci-app-singbox-ui/htdocs luci-app-singbox-ui/root"

if [ "$fail" -eq 0 ]; then
    echo "OK"
    exit 0
fi
exit 1
