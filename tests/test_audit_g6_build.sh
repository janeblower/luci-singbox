#!/bin/sh
# tests/test_audit_g6_build.sh
#
# Regression coverage for audit group G6 (build scripts / packaging / i18n):
#
#   12.1 — scripts/regen-po.sh must be deterministic: `#:` location comments
#          are repo-relative (no absolute /home/... homedir paths, no stale
#          repo name), output is --sort-output stable, and POT-Creation-Date
#          is pinned so a no-string-change regen is a no-op diff. The committed
#          .pot/.po must already satisfy this (no leaked absolute paths).
#
#   12.2 — scripts/build-apk.sh with no version arg must NOT derive an
#          apk-invalid version (e.g. 'bbolt-latest') from an unfiltered
#          `git describe`. It must (a) match only v* tags, (b) fall back to
#          0.0.0-r<commitcount> when none exist, and (c) hard-fail on any
#          version that is not X.Y.Z[-rN].
#
#   12.4 — luci-singbox-ui/Makefile install loop must hard-fail (exit 1) on an
#          unknown/typo'd mode instead of silently degrading to 0644, matching
#          build-apk.sh's behaviour.
#
# Host-runnable: pure shell + gettext tools + git, no VM/rpcd needed.
set -e
cd "$(dirname "$0")/.."

REGEN=scripts/regen-po.sh
BUILDSH=scripts/build-apk.sh
MAKEFILE=luci-singbox-ui/Makefile
POT=luci-singbox-ui/po/templates/luci-singbox-ui.pot
PO=luci-singbox-ui/po/ru/luci-singbox-ui.po

for f in "$REGEN" "$BUILDSH" "$MAKEFILE" "$POT" "$PO"; do
    [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }
done

fail=0

# ---------------------------------------------------------------------------
# 12.1 — committed .pot/.po are portable (no leaked absolute homedir paths)
# ---------------------------------------------------------------------------
echo "-- 12.1 committed .pot/.po carry no absolute /home paths"
if grep -q '/home/' "$POT"; then
    echo "FAIL: $POT still contains absolute /home paths"; fail=1
fi
if grep -q '/home/' "$PO"; then
    echo "FAIL: $PO still contains absolute /home paths"; fail=1
fi
echo "-- 12.1 location comments are repo-relative (htdocs/...)"
if ! grep -q '^#: htdocs/luci-static/' "$POT"; then
    echo "FAIL: $POT has no repo-relative '#: htdocs/...' location comments"; fail=1
fi
echo "-- 12.1 POT-Creation-Date is pinned (not a live timestamp)"
pot_date=$(grep '^"POT-Creation-Date:' "$POT" || true)
case "$pot_date" in
    *"2026-06-12 00:00+0000"*) : ;;
    *) echo "FAIL: $POT POT-Creation-Date not pinned: $pot_date"; fail=1 ;;
esac
echo "-- 12.1 regen-po.sh pins the date and sorts output"
grep -q -- '--sort-output' "$REGEN" \
    || { echo "FAIL: regen-po.sh must pass --sort-output for stable ordering"; fail=1; }
grep -q 'POT-Creation-Date' "$REGEN" \
    || { echo "FAIL: regen-po.sh must pin POT-Creation-Date"; fail=1; }

# Determinism: regen-po.sh must produce byte-identical output on repeated
# runs against the *same* sources. We assert internal determinism (run twice,
# compare) rather than "committed == fresh regen", because the latter races
# against unrelated JS edits in flight (line-number-only `#:` churn) — the
# actual non-determinism 12.1 removes is the timestamp + absolute paths +
# unstable ordering, all of which this catches. The committed files' own
# byte state is preserved/restored around the runs.
# Only run when the gettext toolchain is present (OpenWrt rootfs lacks it).
if command -v xgettext >/dev/null 2>&1 && command -v msgmerge >/dev/null 2>&1; then
    echo "-- 12.1 regen-po.sh is internally deterministic (two runs identical)"
    cp "$POT" /tmp/g6_pot.orig
    cp "$PO" /tmp/g6_po.orig
    if sh "$REGEN" >/tmp/g6_regen.log 2>&1; then
        cp "$POT" /tmp/g6_pot.run1
        cp "$PO" /tmp/g6_po.run1
        if sh "$REGEN" >>/tmp/g6_regen.log 2>&1; then
            cmp -s /tmp/g6_pot.run1 "$POT" \
                || { echo "FAIL: regen-po.sh produced a different $POT on a 2nd run"; fail=1; }
            cmp -s /tmp/g6_po.run1 "$PO" \
                || { echo "FAIL: regen-po.sh produced a different $PO on a 2nd run"; fail=1; }
        else
            echo "FAIL: regen-po.sh exited non-zero (2nd run)"; cat /tmp/g6_regen.log; fail=1
        fi
        # The regen must not leak absolute paths or drift the pinned date.
        grep -q '/home/' "$POT" && { echo "FAIL: regen-po.sh re-introduced /home paths in $POT"; fail=1; }
        grep -q "POT-Creation-Date: 2026-06-12 00:00+0000" "$POT" \
            || { echo "FAIL: regen-po.sh did not keep the date pinned in $POT"; fail=1; }
    else
        echo "FAIL: regen-po.sh exited non-zero (1st run)"; cat /tmp/g6_regen.log; fail=1
    fi
    # Restore exact committed bytes regardless of regen side effects.
    cp /tmp/g6_pot.orig "$POT"
    cp /tmp/g6_po.orig "$PO"
    rm -f /tmp/g6_pot.orig /tmp/g6_po.orig /tmp/g6_pot.run1 /tmp/g6_po.run1 /tmp/g6_regen.log
else
    echo "  SKIP determinism check (xgettext/msgmerge not available)"
fi

# ---------------------------------------------------------------------------
# 12.2 — build-apk.sh version derivation/validation
# ---------------------------------------------------------------------------
echo "-- 12.2 build-apk.sh filters git describe to v* tags only"
grep -q -- "git describe --tags --abbrev=0 --match 'v\\*'" "$BUILDSH" \
    || { echo "FAIL: build-apk.sh must restrict git describe to --match 'v*'"; fail=1; }
echo "-- 12.2 build-apk.sh has a deterministic 0.0.0-r<N> fallback"
grep -q '0.0.0-r\$(git rev-list --count HEAD' "$BUILDSH" \
    || { echo "FAIL: build-apk.sh must fall back to 0.0.0-r<rev-count>"; fail=1; }
echo "-- 12.2 build-apk.sh validates the version against X.Y.Z[-rN]"
grep -q '\^\[0-9\]+\\.\[0-9\]+\\.\[0-9\]+(-r\[0-9\]+)?\$' "$BUILDSH" \
    || { echo "FAIL: build-apk.sh must validate version with the X.Y.Z[-rN] regex"; fail=1; }

# Behavioural check of the exact derivation+validation logic the script uses.
# (The full script needs the OpenWrt SDK; we exercise only the version block.)
g6_version_resolve() {
    _arg="$1"
    _v="$_arg"
    if [ -z "$_v" ]; then
        _v="$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null | sed 's/^v//')"
        [ -z "$_v" ] && _v="0.0.0-r$(git rev-list --count HEAD 2>/dev/null || echo 0)"
    fi
    printf '%s' "$_v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$' || { echo "__INVALID__"; return 1; }
    printf '%s\n' "$_v"
}
if command -v git >/dev/null 2>&1; then
    echo "-- 12.2 no-arg version never yields a rolling tag (bbolt-latest/latest)"
    noarg="$(g6_version_resolve '' || true)"
    case "$noarg" in
        bbolt-latest|latest|__INVALID__|'')
            echo "FAIL: no-arg version resolved to '$noarg'"; fail=1 ;;
        *)
            # Must be a valid X.Y.Z[-rN] string.
            printf '%s' "$noarg" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-r[0-9]+)?$' \
                || { echo "FAIL: no-arg version '$noarg' is not X.Y.Z[-rN]"; fail=1; }
            ;;
    esac
    echo "-- 12.2 valid explicit versions accepted, garbage rejected"
    for good in 1.2.3 0.0.0-r572 10.20.30 2.0.0-r1; do
        g6_version_resolve "$good" >/dev/null \
            || { echo "FAIL: valid version '$good' was rejected"; fail=1; }
    done
    for bad in bbolt-latest latest 1.2 v1.2.3 1.2.3-beta 1.2.3.4 ''x; do
        if g6_version_resolve "$bad" >/dev/null 2>&1; then
            echo "FAIL: invalid version '$bad' was accepted"; fail=1
        fi
    done
else
    echo "  SKIP 12.2 behavioural check (git not available)"
fi

# ---------------------------------------------------------------------------
# 12.4 — Makefile install loop hard-fails on unknown mode (no 0644 degrade)
# ---------------------------------------------------------------------------
echo "-- 12.4 Makefile install loop hard-fails on unknown mode"
# The catch-all must NOT install (no `install -m 0644 ... "\$(1)" `) and must
# echo+exit 1 instead. We assert the source shape directly...
if grep -E '^\s*\*\)\s*install -m 0644' "$MAKEFILE" >/dev/null 2>&1; then
    echo "FAIL: Makefile catch-all still silently installs unknown modes as 0644"; fail=1
fi
grep -q "case \"\$\$mode\" in" "$MAKEFILE" \
    || { echo "FAIL: Makefile no longer dispatches on \$\$mode"; fail=1; }
grep -Eq '\*\).*unknown mode.*exit 1' "$MAKEFILE" \
    || { echo "FAIL: Makefile catch-all must echo 'unknown mode' and exit 1"; fail=1; }
echo "-- 12.4 Makefile enumerates data) explicitly (parity with build-apk.sh)"
grep -Eq '\bdata\)\s*install -m 0644' "$MAKEFILE" \
    || { echo "FAIL: Makefile must enumerate data) -> 0644 explicitly"; fail=1; }

# ...and verify the equivalent shell loop body actually hard-fails at runtime
# (make strips one '$' from '$$mode' and joins the backslash continuations, so
# the recipe executes exactly this case-dispatch).
g6_install_loop() {
    DEST="$1"; MAN="$2"
    while IFS="$(printf '\t')" read -r src dst mode; do
        case "$src" in '#'*|'') continue ;; esac
        install -d "$DEST/$(dirname "$dst")" 2>/dev/null
        case "$mode" in
            bin)  : ;;
            conf) : ;;
            data) : ;;
            *)    echo "install-manifest.txt: unknown mode '$mode' for $src" >&2; exit 1 ;;
        esac
    done < "$MAN"
}
echo "-- 12.4 runtime: valid modes pass, typo'd mode exits 1"
TMP="$(mktemp -d)"
printf 'a.uc\tusr/x/a.uc\tbin\nb.json\tetc/b\tdata\nc\td\tconf\n' > "$TMP/ok.tsv"
printf 'a.uc\tusr/x/a.uc\tbinn\n' > "$TMP/bad.tsv"
if ! ( g6_install_loop "$TMP/dst" "$TMP/ok.tsv" ); then
    echo "FAIL: valid manifest unexpectedly failed the install loop"; fail=1
fi
if ( g6_install_loop "$TMP/dst" "$TMP/bad.tsv" ) 2>/dev/null; then
    echo "FAIL: typo'd mode 'binn' did not hard-fail the install loop"; fail=1
fi
rm -rf "$TMP"

# ---------------------------------------------------------------------------
if [ "$fail" -ne 0 ]; then
    echo "FAIL: audit G6 build checks"
    exit 1
fi
echo "OK"
