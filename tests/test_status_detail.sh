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

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
HANDLER="$PWD/luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui"

# Minimal: list method shows status_detail
out=$("$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" list 2>/dev/null)
echo "$out" | grep -q 'status_detail' \
    && echo "PASS: status_detail in list" \
    || { echo "FAIL: status_detail not advertised; out=$out"; exit 1; }

# Call status_detail and assert all required keys present.
out=$(echo '{}' | "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call status_detail 2>/dev/null)
for k in status running last_generate_ts last_apply_result config_hash schema_version package_version service_start_ts now; do
    echo "$out" | grep -q "\"$k\":" \
        || { echo "FAIL: missing key $k in $out"; exit 1; }
done
echo "PASS: status_detail returns all required keys"

# ---- S5-PERF: package_version is cached on disk; opkg is forked at most once ----
# rpcd spawns a fresh handler process per ubus call, so an in-memory cache can't
# survive. The handler persists the parsed version under $SINGBOX_VARLIB/pkg_version
# and only forks `opkg list-installed` on a cache miss. Prove it: stub `opkg` on
# PATH so each invocation bumps a counter file; two status_detail calls against a
# clean, isolated VARLIB must fork opkg exactly once (second call reads the cache).
CACHE_TMP=$(mktemp -d)
trap 'rm -rf "$CACHE_TMP"' EXIT
mkdir -p "$CACHE_TMP/bin" "$CACHE_TMP/varlib"
COUNTER="$CACHE_TMP/opkg_calls"
: > "$COUNTER"

# opkg stub: count invocations, emit the install line the handler parses.
cat >"$CACHE_TMP/bin/opkg" <<EOF
#!/bin/sh
echo x >> "$COUNTER"
echo "luci-app-singbox-ui - 9.9.9-test"
EOF
chmod +x "$CACHE_TMP/bin/opkg"

run_detail() {
    echo '{}' | env PATH="$CACHE_TMP/bin:$PATH" SINGBOX_VARLIB="$CACHE_TMP/varlib" \
        "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call status_detail 2>/dev/null
}

out1=$(run_detail)
out2=$(run_detail)

# Second call must report the same cached version the first derived from opkg.
echo "$out1" | grep -q '"package_version":"9.9.9-test"' \
    || { echo "FAIL: first call did not derive version from opkg stub; out=$out1"; exit 1; }
echo "$out2" | grep -q '"package_version":"9.9.9-test"' \
    || { echo "FAIL: second call lost cached version; out=$out2"; exit 1; }

# The cache file must exist after the first miss.
[ -s "$CACHE_TMP/varlib/pkg_version" ] \
    || { echo "FAIL: pkg_version cache file not written under SINGBOX_VARLIB"; exit 1; }

# Exactly one opkg fork across both calls: first call misses (forks), second hits
# the cache (0 additional forks). More than one means the cache is not consulted.
forks=$(wc -l < "$COUNTER" | tr -d ' ')
[ "$forks" = "1" ] \
    || { echo "FAIL: expected exactly 1 opkg fork (cache miss once), got $forks"; exit 1; }
echo "PASS: status_detail caches package_version (1 opkg fork)"
