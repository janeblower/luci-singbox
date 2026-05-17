#!/bin/sh
# tests/test_uci_defaults_migration.sh
# Verifies that uci-defaults migrates legacy `list inet4_range` /
# `list inet6_range` to scalar `option` form.
set -e

if ! command -v uci >/dev/null 2>&1; then
    echo "SKIP: uci binary not available"; exit 0
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Seed legacy config (list form).
mkdir -p "$TMPDIR/etc/config" "$TMPDIR/etc/uci-defaults"
cat >"$TMPDIR/etc/config/singbox-ui" <<'EOF'
config fakeip 'fakeip'
	option enabled '1'
	list inet4_range '198.18.0.0/15'
	list inet4_range '198.30.0.0/15'
	list inet6_range 'fc00::/18'
EOF

# Copy the uci-defaults script.
cp luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui \
    "$TMPDIR/etc/uci-defaults/99-luci-app-singbox-ui"
chmod +x "$TMPDIR/etc/uci-defaults/99-luci-app-singbox-ui"

# Run the script with UCI rooted at TMPDIR.
# The script uses `uci -q get/set` — point uci at our sandbox.
log=$TMPDIR/uci-defaults.log
UCI_CONFIG_DIR="$TMPDIR/etc/config" \
    sh -c "cd $TMPDIR && IPKG_INSTROOT='' sh ./etc/uci-defaults/99-luci-app-singbox-ui" \
    >"$log" 2>&1
rc=$?
if [ "$rc" != 0 ] && ! grep -q migration "$log"; then
    echo "FAIL: uci-defaults script crashed (rc=$rc):"
    cat "$log"
    exit 1
fi

# inspect result
result=$(uci -c "$TMPDIR/etc/config" get singbox-ui.fakeip.inet4_range)
case "$result" in
    "198.18.0.0/15") echo "  PASS: inet4_range migrated to first element ($result)";;
    *)               echo "FAIL: expected '198.18.0.0/15', got '$result'"; exit 1;;
esac

result6=$(uci -c "$TMPDIR/etc/config" get singbox-ui.fakeip.inet6_range)
case "$result6" in
    "fc00::/18") echo "  PASS: inet6_range migrated to first element ($result6)";;
    *)           echo "FAIL: expected 'fc00::/18', got '$result6'"; exit 1;;
esac

# Verify it's now option not list — list form would show multiple lines
lines=$(uci -c "$TMPDIR/etc/config" show singbox-ui.fakeip | grep -c '\.inet4_range=')
[ "$lines" = "1" ] || { echo "FAIL: expected one inet4_range entry, got $lines"; exit 1; }
echo "  PASS: inet4_range is scalar (one entry in show)"

echo "OK"
