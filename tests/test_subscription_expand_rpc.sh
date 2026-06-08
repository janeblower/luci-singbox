#!/bin/sh
# tests/test_subscription_expand_rpc.sh
# Validates singbox-ui::subscription_expand RPC: feeds a synthetic
# sub_<name>.txt with 3 share-link URLs and asserts endpoints array.
set -e
cd "$(dirname "$0")/.."

H=luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui
if [ ! -x "$H" ]; then echo "FAIL: $H missing"; exit 1; fi

if command -v ucode >/dev/null 2>&1; then
    UCODE_BIN=$(command -v ucode)
    UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
    UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
    [ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
    echo "SKIP test_subscription_expand_rpc (ucode missing)"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SUB_NAME=e1test
SUB_PATH="$TMP/sub_${SUB_NAME}.txt"

cat > "$SUB_PATH" <<'EOF'
vless://aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee@1.2.3.4:443?type=tcp&security=reality&pbk=xxx&fp=chrome&sid=yyy&flow=xtls-rprx-vision#endpoint-jp
ss://aes-256-gcm:testpw@5.6.7.8:8388#endpoint-us
trojan://secretpass@9.9.9.9:443#endpoint-fr
EOF

# Override SUB_TMPDIR via env so subscription_expand.uc reads from $TMP.
# Env-vars must apply to the ucode process (right of the pipe), not to printf.
response=$(printf '{"name":"'"$SUB_NAME"'"}' | \
    env SUB_TMPDIR="$TMP" SINGBOX_UI_SUB_DIR="$TMP" \
    "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" call subscription_expand 2>&1) || {
    echo "FAIL rpc invocation: $response"; exit 1; }

echo "$response" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' || {
    echo "FAIL response not ok: $response"; exit 1; }
echo "$response" | grep -q '"name"[[:space:]]*:[[:space:]]*"e1test"' || {
    echo "FAIL response missing name: $response"; exit 1; }

# Count endpoints by counting "fields" keys — each outer endpoint wrapper has
# exactly one "fields" key; the inner fields object itself does not contain one.
# Use awk -F for BusyBox compatibility (grep -o is not reliable on OpenWrt ash).
n=$(printf '%s' "$response" | awk -F'"fields"' '{print NF-1}')
if [ "$n" -ne 3 ]; then
    echo "FAIL expected 3 endpoints (fields keys), got $n in: $response"
    exit 1
fi

echo "PASS test_subscription_expand_rpc"
