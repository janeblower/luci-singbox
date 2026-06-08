#!/bin/sh
# Container entrypoint for browser tests.
# Boots ubusd → rpcd → uhttpd in one shell; uhttpd is PID 1-soft and
# its exit ends the container.
set -eu

# Required dirs (openwrt/rootfs ships these empty or missing).
mkdir -p /var/run /var/lock /var/log /var/state /tmp /usr/libexec/rpcd

# Seed root password via the only mechanism present in openwrt/rootfs.
# `passwd` reads stdin twice (new + retype) and writes $5$sha-256 to /etc/shadow.
if [ -z "$(awk -F: '$1=="root"{print $2}' /etc/shadow 2>/dev/null)" ]; then
    printf 'admin\nadmin\n' | passwd root >/dev/null 2>&1 || true
fi

# Stub /etc/board.json — LuCI bootstrap header reads this via the
# `system board` ubus call. Without it, header.ut crashes with
# "left-hand side expression is null" → HTTP 500.
[ -f /etc/board.json ] || cat > /etc/board.json <<'JSON'
{
    "kernel":   "6.6.99",
    "hostname": "OpenWrt-test",
    "system":   "x86_64",
    "model":    { "id": "test", "name": "Test Container" },
    "release":  {
        "distribution": "OpenWrt",
        "version":      "25.12.3",
        "revision":     "r0",
        "target":       "x86/64",
        "description":  "OpenWrt 25.12.3 r0 (browser-test container)"
    },
    "network":  {},
    "switch":   {}
}
JSON

# Minimal rpcd `system` handler. Replaces procd's normal registration,
# which is unavailable in a containerised LuCI. Returns board.json for
# `ubus call system board` and a zeroed `system info` payload.
[ -x /usr/libexec/rpcd/system ] || {
    cat > /usr/libexec/rpcd/system <<'SHIM'
#!/bin/sh
case "$1" in
    list) echo '{"board":{},"info":{}}' ;;
    call)
        case "$2" in
            board) cat /etc/board.json ;;
            info)  echo '{"uptime":0,"localtime":0,"load":[0,0,0],"memory":{"total":0,"free":0,"shared":0,"buffered":0,"available":0},"swap":{"total":0,"free":0},"root":{}}' ;;
            *)     echo '{}' ;;
        esac
    ;;
esac
SHIM
    chmod +x /usr/libexec/rpcd/system
}

# Stub /etc/init.d/sing-box if missing — the singbox-ui rpcd handler calls
# it on Save & Apply paths.
[ -x /etc/init.d/sing-box ] || {
    cat > /etc/init.d/sing-box <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x /etc/init.d/sing-box
}

# Launch the stack — must be ONE shell session. `docker exec -d` style
# detachment kills the children with the exec frame.
ubusd -A /usr/share/acl.d &
UBUSD_PID=$!

# Wait for ubus socket (max 5s). BusyBox sleep is integer-only.
# OpenWrt 25.x ships ubus 2024-x which defaults to /var/run/ubus/ubus.sock.
UBUS_SOCK=/var/run/ubus/ubus.sock
i=0; while [ ! -S "$UBUS_SOCK" ] && [ $i -lt 5 ]; do
    i=$((i+1)); sleep 1
done
[ -S "$UBUS_SOCK" ] || { echo "ERROR: ubusd socket failed to appear"; exit 1; }

rpcd &
RPCD_PID=$!
sleep 1

# uhttpd in foreground = PID 1 of the process group from docker's view.
exec uhttpd -f -p 0.0.0.0:80 -h /www -c /etc/config/uhttpd
