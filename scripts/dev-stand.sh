#!/bin/sh
# dev-stand.sh — a throwaway OpenWrt container running THIS checkout's LuCI app,
# so a change can be looked at in a real browser instead of inferred from tests.
#
# The package trees are bind-mounted, not installed: edit a file in the checkout,
# reload the page, see it. No rebuild, no apk, no re-run of this script.
#
#   sh scripts/dev-stand.sh up [<subscription-url>]   build + run + seed + start
#   sh scripts/dev-stand.sh traffic                   fake connections (Monitoring)
#   sh scripts/dev-stand.sh sh                        shell inside the container
#   sh scripts/dev-stand.sh down                      remove it
#
# `up` prints the URL. Login is root/admin. The subscription URL is passed on the
# command line and lives only in the container's UCI — never in the repo.
set -eu
cd "$(dirname "$0")/.."

CNAME=singbox-dev-stand
IMG=singbox-dev-stand:2
PORT="${DEV_STAND_PORT:-8181}"
# Long, slow downloads through the container's own SOCKS inbound. Anything with a
# big body and no rate limit will do; the point is connections that stay OPEN so
# the Monitoring table has rows to draw.
TRAFFIC_URL="https://speed.cloudflare.com/__down?bytes=300000000"

build() {
    docker image inspect "$IMG" >/dev/null 2>&1 && return 0
    echo "==> building $IMG"
    # procd is what registers the `service` ubus object that init.d scripts and
    # the LuCI status panel talk to; the stock openwrt/rootfs image has no init.
    docker build -t "$IMG" -f - tests/browser-container <<'DOCKERFILE'
FROM openwrt/rootfs:x86_64-25.12.3
# sing-box-extended (shtorm-7 fork, our feed) — the project's DEFAULT core and the
# only one that supports the xhttp transport providers ship. Stock sing-box
# rejects an xhttp outbound at load ("unknown transport type: xhttp") and the whole
# config fails — that's expected, not a bug; the fix is running extended.
RUN apk update \
 && apk add luci uhttpd rpcd ucode-mod-fs ucode-mod-uci curl ca-bundle procd jsonfilter \
 && echo "https://janeblower.github.io/luci-singbox/25.12/x86_64/sing-box/packages.adb" >> /etc/apk/repositories \
 && apk update --allow-untrusted \
 && apk add --allow-untrusted sing-box-extended \
 && rm -rf /var/cache/apk/*
COPY entrypoint.sh /sbin/entrypoint.sh
RUN chmod +x /sbin/entrypoint.sh && \
    sed -i 's|^exec uhttpd|[ -x /sbin/procd ] \&\& { /sbin/procd \& sleep 1; }\nexec uhttpd|' /sbin/entrypoint.sh
EXPOSE 80
ENTRYPOINT ["/sbin/entrypoint.sh"]
DOCKERFILE
}

up() {
    sub="${1:-}"
    build
    docker rm -f "$CNAME" >/dev/null 2>&1 || true
    echo "==> starting $CNAME"
    # 0.0.0.0 so the page is reachable from the Windows side of WSL, not just
    # from inside the VM. This is a dev toy on localhost — it holds no secrets
    # beyond the subscription you hand it.
    docker run -d --name "$CNAME" --privileged -p "0.0.0.0:${PORT}:80" \
        -v "$PWD/singbox-ui/root/usr/share/singbox-ui:/usr/share/singbox-ui:ro" \
        -v "$PWD/singbox-ui/root/usr/libexec/rpcd/singbox-ui:/usr/libexec/rpcd/singbox-ui:ro" \
        -v "$PWD/singbox-ui/root/etc/init.d/singbox-ui:/etc/init.d/singbox-ui:ro" \
        -v "$PWD/singbox-ui/root/etc/capabilities/singbox-ui.json:/etc/capabilities/singbox-ui.json:ro" \
        -v "$PWD/luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui:/www/luci-static/resources/view/singbox-ui:ro" \
        -v "$PWD/luci-app-singbox-ui/root/usr/share/luci/menu.d/luci-singbox-ui.json:/usr/share/luci/menu.d/luci-singbox-ui.json:ro" \
        -v "$PWD/luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-singbox-ui.json:/usr/share/rpcd/acl.d/luci-singbox-ui.json:ro" \
        "$IMG" >/dev/null

    i=0
    while ! docker exec "$CNAME" ubus list 2>/dev/null | grep -q '^singbox-ui$'; do
        i=$((i + 1))
        [ "$i" -lt 30 ] || { echo "FAIL: rpcd never registered singbox-ui" >&2; docker logs "$CNAME" >&2; exit 1; }
        sleep 1
    done

    # uci-defaults never run here (nothing installs the package), so seed the
    # shipped config by hand.
    docker cp singbox-ui/root/etc/config/singbox-ui "$CNAME:/etc/config/singbox-ui"

    # ...and then REPLAY the uci-defaults, because a real install lays the config
    # down and runs them next. Skipping this is why the stand showed only the two
    # rule-sets from the shipped config: the other 23 built-ins are created by
    # 92-*, not by the config file. 99-* is skipped on purpose — it only migrates
    # legacy UCI shapes, which a freshly-copied shipped config cannot have.
    # SINGBOX_UCI is the seam the scripts take for exactly this (the uci CLI does
    # not honour UCI_CONFIG_DIR).
    docker cp singbox-ui/root/etc/uci-defaults "$CNAME:/tmp/uci-defaults" >/dev/null
    docker exec "$CNAME" sh -c '
        for f in /tmp/uci-defaults/9[0-8]-*; do
            [ -f "$f" ] || continue
            sh "$f" >/dev/null 2>&1 || echo "WARN: uci-defaults $(basename "$f") failed" >&2
        done'

    # Stand-local overrides, AFTER the defaults so they win: Clash API on, tproxy
    # off (no LAN to intercept), a SOCKS inbound so `traffic` has somewhere to dial.
    docker exec "$CNAME" sh -c '
        uci -q batch <<EOF
set singbox-ui.clash_api.enabled=1
set singbox-ui.tproxy_in.enabled=0
set singbox-ui.dns_in.enabled=0
set singbox-ui.socks_in=inbound
set singbox-ui.socks_in.enabled=1
set singbox-ui.socks_in.protocol=mixed
set singbox-ui.socks_in.listen=127.0.0.1
set singbox-ui.socks_in.listen_port=1080
EOF
        uci commit singbox-ui'

    if [ -n "$sub" ]; then
        echo "==> seeding subscription + two interface-bound direct outbounds"
        docker exec -e SUB="$sub" "$CNAME" sh -c '
            uci -q batch <<EOF
set singbox-ui.sub=outbound
set singbox-ui.sub.enabled=1
set singbox-ui.sub.type=subscription
set singbox-ui.sub.sub_multi=1
set singbox-ui.sub.sub_selector_type=selector
set singbox-ui.wan_direct=outbound
set singbox-ui.wan_direct.enabled=1
set singbox-ui.wan_direct.type=direct
set singbox-ui.wan_direct.bind_interface=eth0
set singbox-ui.lo_direct=outbound
set singbox-ui.lo_direct.enabled=1
set singbox-ui.lo_direct.type=direct
set singbox-ui.lo_direct.bind_interface=lo
EOF
            uci set singbox-ui.sub.sub_url="$SUB"
            uci commit singbox-ui
            ubus call singbox-ui refresh "{\"what\":\"subscriptions\"}" >/dev/null'
    fi

    docker exec "$CNAME" /etc/init.d/singbox-ui start >/dev/null 2>&1 || true
    sleep 5
    # A config sing-box refuses leaves the Dashboard permanently on its "service
    # stopped" plaque, which looks like a UI bug and isn't one. Say why instead.
    if ! docker exec "$CNAME" sh -c 'curl -sf -m3 http://127.0.0.1:9090/version >/dev/null'; then
        echo
        echo "  !! sing-box did not come up. Its own verdict on the generated config:"
        docker exec "$CNAME" sh -c 'sing-box check -c /tmp/singbox-ui.json 2>&1 | head -3' \
            | sed 's/^/     /'
    fi
    echo
    echo "  http://localhost:${PORT}/cgi-bin/luci      root / admin"
    echo "  edits in the checkout are live — just reload the page"
    echo "  sh scripts/dev-stand.sh traffic   # populate the Monitoring tab"
}

traffic() {
    docker exec "$CNAME" sh -c 'netstat -lnt | grep -q 127.0.0.1:1080' \
        || { echo "FAIL: no SOCKS inbound on 1080 — is sing-box running?" >&2; exit 1; }
    echo "==> opening 5 slow downloads through the container's SOCKS inbound"
    i=0
    while [ "$i" -lt 5 ]; do
        # Each exec re-dials when its curl ends, so the rows persist. They die
        # with the container.
        docker exec -d "$CNAME" sh -c \
            "while true; do curl -s --socks5-hostname 127.0.0.1:1080 --limit-rate 15k -o /dev/null -m 600 '$TRAFFIC_URL'; done"
        i=$((i + 1))
    done
    sleep 8
    docker exec "$CNAME" sh -c 'curl -s -m3 http://127.0.0.1:9090/connections' \
        | tr '{' '\n' | grep -c chains | sed 's/^/    live connections: /'
}

case "${1:-}" in
    up)      shift; up "${1:-}" ;;
    traffic) traffic ;;
    sh)      docker exec -it "$CNAME" sh ;;
    down)    docker rm -f "$CNAME" >/dev/null 2>&1 && echo "removed $CNAME" ;;
    *)       sed -n '2,14p' "$0" | sed 's|^# \{0,1\}||'; exit 1 ;;
esac
