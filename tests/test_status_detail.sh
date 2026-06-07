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
