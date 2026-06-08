#!/usr/bin/env bash
# tests/test_browser.sh — headless-Chrome integration suite against a
# containerised LuCI stack. Builds tests/browser-container/, launches
# one container per run, snapshots /etc/config/singbox-ui inside it, then
# restores before each test file. Puppeteer/Chrome run on the host via bun.
set -eu
set -o pipefail
cd "$(dirname "$0")/.."

command -v bun    >/dev/null 2>&1 || { echo "ERROR: bun missing (curl -fsSL https://bun.sh/install | bash)"; exit 2; }
command -v docker >/dev/null 2>&1 || { echo "ERROR: docker missing"; exit 2; }

# Build/cache image keyed on the container source files.
IMG_HASH=$(cat tests/browser-container/Dockerfile \
               tests/browser-container/entrypoint.sh \
               tests/browser-container/uhttpd.conf \
               | sha256sum | cut -c1-12)
IMG="luci-singbox-ui-browser:${IMG_HASH}"
docker image inspect "$IMG" >/dev/null 2>&1 \
    || { echo "==> building $IMG"; docker build -t "$IMG" tests/browser-container; }

CNAME="singbox-ui-test-$$"

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

echo "==> launching container $CNAME"
docker run -d --name "$CNAME" \
    -p "127.0.0.1::80" \
    -v "$PWD/luci-app-singbox-ui/root/www:/www:ro" \
    -v "$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui:/usr/share/singbox-ui:ro" \
    -v "$PWD/luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui:/usr/libexec/rpcd/singbox-ui:ro" \
    -v "$PWD/tests/browser/fixtures:/seed:ro" \
    "$IMG" >/dev/null
PORT=$(docker port "$CNAME" 80/tcp | head -1 | awk -F: '{print $NF}')
[ -n "$PORT" ] || { echo "ERROR: failed to read mapped port" >&2; exit 1; }
echo "==> container listening on 127.0.0.1:${PORT}"

# Wait for HTTP ready (max 60s).
i=0
while [ "$(curl -s -o /dev/null -w '%{http_code}' \
              "http://127.0.0.1:${PORT}/cgi-bin/luci" 2>/dev/null || echo 000)" = "000" ]; do
    i=$((i+1))
    if [ $i -gt 60 ]; then
        echo "FAIL: container not responding after 60s" >&2
        docker logs "$CNAME" >&2 || true
        exit 1
    fi
    sleep 1
done

# Seed UCI from fixture, take a baseline copy inside the container,
# install bun deps + Chrome (once per worktree).
docker exec "$CNAME" sh -c 'cp /seed/baseline.uci /etc/config/singbox-ui && cp /etc/config/singbox-ui /tmp/uci.baseline'
docker exec "$CNAME" /etc/init.d/rpcd reload || true

LOCK_HASH=$(sha256sum tests/browser/bun.lock | cut -c1-12)
STAMP="tests/browser/node_modules/.lock-${LOCK_HASH}"
if [ ! -e "$STAMP" ]; then
    echo "==> bun install (lockfile changed)"
    ( cd tests/browser && bun install --frozen-lockfile )
    touch "$STAMP"
fi
if [ ! -d "$HOME/.cache/puppeteer/chrome" ]; then
    echo "==> puppeteer Chrome install (one-time, ~200MB)"
    ( cd tests/browser && bunx puppeteer browsers install chrome )
fi

export BROWSER_URL="http://127.0.0.1:${PORT}/cgi-bin/luci"
export DOCKER_NAME="$CNAME"
export LUCI_USER="root"
export LUCI_PASS="admin"

fail=0
for t in tests/browser/[0-9]*.mjs; do
    [ -e "$t" ] || continue
    echo
    echo "==> $t"
    # Per-test UCI snapshot/restore.
    docker exec "$CNAME" cp /tmp/uci.baseline /etc/config/singbox-ui
    docker exec "$CNAME" /etc/init.d/rpcd reload || true
    sleep 1  # let rpcd settle after reload before the test issues its first call
    if ! ( cd tests/browser && bun "$(basename "$t")" ); then
        echo "FAIL: $t"
        docker logs --tail 60 "$CNAME" >&2 || true
        fail=1
    fi
done

[ "$fail" -eq 0 ] || exit 1
echo
echo "ALL PASS: test_browser"
