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
