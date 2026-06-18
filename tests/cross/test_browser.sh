#!/usr/bin/env bash
# tests/test_browser.sh — headless-Chrome integration suite against a
# containerised LuCI stack. Builds tests/browser-container/, launches
# one container per run, snapshots /etc/config/singbox-ui inside it, then
# restores before each test file. Puppeteer/Chrome run on the host via bun.
set -eu
cd "$(dirname "$0")/../.."

# tests/run.sh globs the test files and runs each one inside whichever
# environment is active. This suite runs for real ONLY in the dedicated
# browser-test CI lane (a host with bun + docker). It must skip gracefully
# everywhere else it gets swept up by run.sh: the OpenWrt qemu VM (sentinel
# below) and the packaging lane (ubuntu, apk-tools but no bun → skip below).
if [ "${SINGBOX_TESTS_IN_VM:-0}" = "1" ]; then
    echo "SKIP test_browser: not runnable inside the OpenWrt qemu VM"
    exit 0
fi

# Missing bun/docker => this is not the browser lane (e.g. the packaging lane).
# Skip gracefully rather than erroring; the browser-test job provides bun+docker
# and runs the suite for real there.
command -v bun    >/dev/null 2>&1 || { echo "SKIP test_browser: bun not available (browser-test lane only)"; exit 0; }
command -v docker >/dev/null 2>&1 || { echo "SKIP test_browser: docker not available (browser-test lane only)"; exit 0; }

# Past the guards => this IS the browser lane. run.sh invokes every test via
# `sh "$t"` (dash on the GitHub ubuntu runner / packaging lane), but the harness
# below needs bash (set -o pipefail + the puppeteer driver). dash would die on
# `set -o pipefail`; the POSIX-safe guards above already ran, so re-exec under
# bash now for the real run. (Kept after the guards so non-browser lanes skip
# cleanly under dash without even needing bash present.)
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
. "$(dirname "$0")/../lib/sb_helpers.sh"
set -o pipefail

# Build/cache image keyed on the container source files.
IMG_HASH=$(cat tests/browser-container/Dockerfile \
               tests/browser-container/entrypoint.sh \
               tests/browser-container/uhttpd.conf \
               | sha256sum | cut -c1-12)
IMG="luci-singbox-ui-browser:${IMG_HASH}"
# CI restores a local buildx layer cache into BUILDX_CACHE (the path the
# actions/cache step in build.yml saves/restores) — but only buildx can read
# --cache-from/--cache-to. On a fresh runner the Docker image store is empty, so
# the `docker image inspect` guard always misses and we must actually build;
# feeding the restored layer cache is what makes that build fast (and what makes
# the cache step do real work instead of saving an empty dir). When buildx is
# unavailable, or BUILDX_CACHE is unset (local dev), fall back to a plain build.
BUILDX_CACHE="${BUILDX_CACHE:-}"
if docker image inspect "$IMG" >/dev/null 2>&1; then
    : # image already in the local store (warm local dev) — nothing to build
elif [ -n "$BUILDX_CACHE" ] && docker buildx version >/dev/null 2>&1; then
    echo "==> building $IMG (buildx, local layer cache: $BUILDX_CACHE)"
    mkdir -p "$BUILDX_CACHE"
    docker buildx build \
        --cache-from "type=local,src=${BUILDX_CACHE}" \
        --cache-to "type=local,dest=${BUILDX_CACHE},mode=max" \
        --load -t "$IMG" tests/browser-container
else
    echo "==> building $IMG"
    docker build -t "$IMG" tests/browser-container
fi

CNAME="singbox-ui-test-$$"

# 4-package split: the real etc/init.d/singbox-ui runs `sing-box run` via procd
# (absent in this container). Mount a no-op stub by the SAME name the rpcd
# handler shells (SINGBOX_INIT=/etc/init.d/singbox-ui), so restart/generate RPCs
# return 0 without procd hanging.
STUB_INIT="$(mktemp)"
printf '#!/bin/sh\nexit 0\n' > "$STUB_INIT"; chmod +x "$STUB_INIT"

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; rm -f "$STUB_INIT"; }
trap cleanup EXIT INT TERM

echo "==> launching container $CNAME"
# Bind-mount granularity: never mount the plugin's `root/www` over the image's
# `/www` — the plugin ships only a sentinel placeholder there, which would
# mask LuCI's own /www/cgi-bin/luci and break login (HTTP 404). Instead, mount
# the asset subdirs into LuCI's existing /www tree.
docker run -d --name "$CNAME" \
    -p "127.0.0.1::80" \
    -v "$PWD/${SB_VIEW}:/www/luci-static/resources/view/singbox-ui:ro" \
    -v "$PWD/${SB_SHARE}:/usr/share/singbox-ui:ro" \
    -v "$PWD/${SB_MENU}:/usr/share/luci/menu.d/luci-singbox-ui.json:ro" \
    -v "$PWD/${SB_ACL}:/usr/share/rpcd/acl.d/luci-singbox-ui.json:ro" \
    -v "$PWD/${SB_RPCD}:/usr/libexec/rpcd/singbox-ui:ro" \
    -v "$STUB_INIT:/etc/init.d/singbox-ui:ro" \
    -v "$PWD/${SB_BACKEND_ROOT}/etc/capabilities/singbox-ui.json:/etc/capabilities/singbox-ui.json:ro" \
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
# This container boots ubusd→rpcd→uhttpd directly (no procd, see entrypoint.sh),
# so `/etc/init.d/rpcd reload` routes through procd's `service` ubus object —
# absent here — and ubus prints "Command failed: Not found" to stderr. The
# reload is a no-op without procd anyway (the handler loads at rpcd startup);
# `|| true` already treats it as best-effort, so silence the stray stderr too.
docker exec "$CNAME" /etc/init.d/rpcd reload 2>/dev/null || true

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
    # See the setup-phase reload above: no procd in this container → the
    # init script's reload hits an absent `service` ubus object and prints
    # "Command failed: Not found". Best-effort + silenced.
    docker exec "$CNAME" /etc/init.d/rpcd reload 2>/dev/null || true
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
