#!/bin/sh
# tests/test_migration_drop_removed.sh — exercises migrate_drop_removed_protocols
# on a fixture config with one of every removed type plus one survivor.
set -eu
cd "$(dirname "$0")/.."

if ! command -v uci >/dev/null 2>&1; then
    echo "SKIP test_migration_drop_removed (uci missing)"; exit 0
fi

CONFIG=/etc/config/singbox-ui
[ -e "$CONFIG" ] && { echo "SKIP: $CONFIG exists, refusing"; exit 0; }

cat > "$CONFIG" <<'EOF'
config inbound 'tproxy_in'
    option enabled '1'
    option protocol 'tproxy'

config inbound 'tun_in'
    option enabled '1'
    option protocol 'tun'

config inbound 'vmess_in'
    option enabled '1'
    option protocol 'vmess'

config outbound 'vless_out'
    option enabled '1'
    option type 'vless'
    option transport 'ws'
    option security 'tls'
    option utls_fingerprint 'firefox'

config outbound 'vmess_out'
    option enabled '1'
    option type 'vmess'

config outbound 'tuic_out'
    option enabled '1'
    option type 'tuic'

config outbound 'anytls_out'
    option enabled '1'
    option type 'anytls'

config outbound 'ssh_out'
    option enabled '1'
    option type 'ssh'

config outbound 'interface_out'
    option enabled '1'
    option type 'interface'
EOF

# Run the uci-defaults script (idempotent, multi-step).
sh luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui >/tmp/mig.log 2>&1 \
    || { echo "FAIL: migration crashed"; cat /tmp/mig.log; rm -f "$CONFIG"; exit 1; }

# Assertions: removed sections must be gone.
for s in tun_in vmess_in vmess_out tuic_out anytls_out ssh_out interface_out; do
    if uci -q get "singbox-ui.$s" >/dev/null 2>&1; then
        echo "FAIL: $s survived migration"; rm -f "$CONFIG"; exit 1
    fi
done

# Assertions: surviving sections must still exist.
for s in tproxy_in vless_out; do
    if ! uci -q get "singbox-ui.$s" >/dev/null 2>&1; then
        echo "FAIL: $s removed by mistake"; rm -f "$CONFIG"; exit 1
    fi
done

# Migration A rename assertions: vless_out kept and transport key renamed.
[ "$(uci -q get singbox-ui.vless_out.transport_type)" = "ws" ] \
    || { echo "FAIL: transport→transport_type not renamed"; rm -f "$CONFIG"; exit 1; }
[ -z "$(uci -q get singbox-ui.vless_out.transport 2>/dev/null)" ] \
    || { echo "FAIL: old transport key not deleted"; rm -f "$CONFIG"; exit 1; }
[ "$(uci -q get singbox-ui.vless_out.tls_enabled)" = "1" ] \
    || { echo "FAIL: security=tls → tls_enabled=1 not applied"; rm -f "$CONFIG"; exit 1; }
[ "$(uci -q get singbox-ui.vless_out.utls_enabled)" = "1" ] \
    || { echo "FAIL: utls_fingerprint set → utls_enabled=1 not applied"; rm -f "$CONFIG"; exit 1; }
echo "PASS: migration A renames applied"

# Idempotent rerun.
sh luci-app-singbox-ui/root/etc/uci-defaults/99-luci-app-singbox-ui >/tmp/mig2.log 2>&1 \
    || { echo "FAIL: rerun crashed"; rm -f "$CONFIG"; exit 1; }

rm -f "$CONFIG"
echo "PASS: test_migration_drop_removed"
