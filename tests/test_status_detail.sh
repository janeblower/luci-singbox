#!/bin/sh
# tests/test_status_detail.sh
set -e
cd "$(dirname "$0")/.."

# Optional shared helpers — silently skip if not present (file may not exist).
if [ -f tests/lib/sb_helpers.sh ]; then
    . tests/lib/sb_helpers.sh
fi

# Use the same rpcd-handler test scaffolding pattern as test_rpcd_handler.sh.
# Detect ucode; SKIP if absent.
: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
HANDLER="$PWD/luci-singbox-ui/root/usr/libexec/rpcd/singbox-ui"

# Minimal: list method shows status_detail
out=$("$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" list 2>/dev/null)
echo "$out" | grep -q 'status_detail' \
    && echo "PASS: status_detail in list" \
    || { echo "FAIL: status_detail not advertised; out=$out"; exit 1; }

# Call status_detail and assert all required keys present.
out=$(echo '{}' | "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call status_detail 2>/dev/null)
for k in status running last_generate_ts last_generate_result last_apply_result last_apply_ts config_hash schema_version package_version service_start_ts now; do
    echo "$out" | grep -q "\"$k\":" \
        || { echo "FAIL: missing key $k in $out"; exit 1; }
done
echo "PASS: status_detail returns all required keys"

# ---- S5-PERF: package_version is cached on disk; apk is forked at most once ----
# rpcd spawns a fresh handler process per ubus call, so an in-memory cache can't
# survive. The handler persists the parsed version under $SINGBOX_VARLIB/pkg_version
# and only forks `apk list --installed` on a cache miss. Prove it: stub `apk` on
# PATH so each invocation bumps a counter file; two status_detail calls against a
# clean, isolated VARLIB must fork apk exactly once (second call reads the cache).
CACHE_TMP=$(mktemp -d)
trap 'rm -rf "$CACHE_TMP"' EXIT
mkdir -p "$CACHE_TMP/bin" "$CACHE_TMP/varlib"
COUNTER="$CACHE_TMP/apk_calls"
: > "$COUNTER"

# apk stub: count invocations, emit the apk-format install line the handler
# parses (version = first token with the package-name prefix stripped). The
# stub ignores its args, like the real `apk list --installed <pkg>` we shell out.
cat >"$CACHE_TMP/bin/apk" <<EOF
#!/bin/sh
echo x >> "$COUNTER"
echo "luci-singbox-ui-9.9.9-test noarch {luci-singbox-ui} (GPL-2.0-or-later) [installed]"
EOF
chmod +x "$CACHE_TMP/bin/apk"

run_detail() {
    echo '{}' | env PATH="$CACHE_TMP/bin:$PATH" SINGBOX_VARLIB="$CACHE_TMP/varlib" \
        "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call status_detail 2>/dev/null
}

out1=$(run_detail)
out2=$(run_detail)

# Exact parse, not grep-substring: a wrong token or an un-stripped prefix would
# still substring-match, so pin the exact parsed value via JSON.
v1=$(printf '%s' "$out1" | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.package_version);')
[ "$v1" = "9.9.9-test" ] \
    || { echo "FAIL: first call parsed version=[$v1], want 9.9.9-test; out=$out1"; exit 1; }
v2=$(printf '%s' "$out2" | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.package_version);')
[ "$v2" = "9.9.9-test" ] \
    || { echo "FAIL: second call lost cached version=[$v2]; out=$out2"; exit 1; }

# The cache file must exist after the first miss.
[ -s "$CACHE_TMP/varlib/pkg_version" ] \
    || { echo "FAIL: pkg_version cache file not written under SINGBOX_VARLIB"; exit 1; }

# Exactly one opkg fork across both calls: first call misses (forks), second hits
# the cache (0 additional forks). More than one means the cache is not consulted.
forks=$(wc -l < "$COUNTER" | tr -d ' ')
[ "$forks" = "1" ] \
    || { echo "FAIL: expected exactly 1 apk fork (cache miss once), got $forks"; exit 1; }
echo "PASS: status_detail caches package_version (1 apk fork)"

# ---- audit 13.2: init.d sed and rpcd ucode pkg_version parsers must agree ----
# Two prod sites prime the SAME /var/lib/singbox-ui/pkg_version cache from
# `apk list --installed luci-singbox-ui`:
#   * etc/init.d/singbox-ui::start_service  — a `sed` one-liner (warm path)
#   * rpcd handler cached_pkg_version()     — split(line," ")[0] + prefix strip
# CLAUDE.md flags these as a coupling that MUST yield identical format. Extract
# the live sed expression from the init.d (so the test can't drift from it) and
# feed the same fixture apk line through BOTH paths; assert byte-identical out.
INITD="$PWD/luci-singbox-ui/root/etc/init.d/singbox-ui"
[ -f "$INITD" ] || { echo "FAIL(13.2): init.d not found at $INITD"; exit 1; }

# Pull the exact `sed -n '...'` script used by start_service. We grep the line
# containing the pkg_version sed and isolate the single-quoted expression.
SED_EXPR=$(grep -E "sed -n 's/\^luci-singbox-ui" "$INITD" | head -1 \
    | sed -n "s/.*sed -n '\([^']*\)'.*/\1/p")
[ -n "$SED_EXPR" ] \
    || { echo "FAIL(13.2): could not extract the pkg_version sed expression from $INITD"; exit 1; }

# pkg_parse_both LINE — run LINE through the init.d sed and through the rpcd
# handler, printing "sed=<…> rpcd=<…>" so a mismatch is self-describing.
assert_parsers_agree() {
    _line="$1"; _want="$2"
    _sed=$(printf '%s\n' "$_line" | sed -n "$SED_EXPR")
    # rpcd side: stub apk to emit exactly $_line, drive status_detail with a
    # fresh VARLIB (force a cache miss → the live ucode parser runs), read back
    # package_version.
    _vl=$(mktemp -d); _bin=$(mktemp -d)
    cat >"$_bin/apk" <<APK
#!/bin/sh
printf '%s\n' "$_line"
APK
    chmod +x "$_bin/apk"
    _rpcd=$(echo '{}' | env PATH="$_bin:$PATH" SINGBOX_VARLIB="$_vl" \
        "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call status_detail 2>/dev/null \
        | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.package_version);')
    rm -rf "$_vl" "$_bin"
    [ "$_sed" = "$_rpcd" ] \
        || { echo "FAIL(13.2): parsers disagree on [$_line]: sed=[$_sed] rpcd=[$_rpcd]"; exit 1; }
    [ "$_sed" = "$_want" ] \
        || { echo "FAIL(13.2): parsed [$_sed] for [$_line], want [$_want]"; exit 1; }
}

# Normal multi-field apk line (the common case).
assert_parsers_agree \
    "luci-singbox-ui-0.0.0-r337 noarch {luci-singbox-ui} (GPL-2.0-or-later) [installed]" \
    "0.0.0-r337"
# Edge case the old ` .*` sed regressed on: a single-token line with NO trailing
# space. rpcd's split(line," ")[0] handled it; the hardened sed must too.
assert_parsers_agree "luci-singbox-ui-1.2.3-r9" "1.2.3-r9"
echo "PASS: init.d sed and rpcd pkg_version parsers are byte-identical (audit 13.2)"
