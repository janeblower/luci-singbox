#!/bin/sh
# Smoke test for tests/browser-container/. Builds the image, runs it,
# waits for HTTP to answer, asserts 200/302/403, tears down.
set -eu
cd "$(dirname "$0")/.."

command -v docker >/dev/null || { echo "SKIP: docker missing"; exit 0; }

IMG="luci-singbox-ui-browser:spike"
CNAME="singbox-ui-spike-$$"
PORT=$(awk 'BEGIN{srand(); print 30000+int(rand()*20000)}')

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT INT TERM

docker build -t "$IMG" tests/browser-container
docker run -d --name "$CNAME" -p "127.0.0.1:${PORT}:80" "$IMG" >/dev/null

i=0
while :; do
    # curl can exit non-zero (e.g. 7 ECONNREFUSED) while port is still binding;
    # tolerate it so `set -e` does not abort the wait loop.
    code=$(curl -s -o /dev/null -w '%{http_code}' \
              "http://127.0.0.1:${PORT}/cgi-bin/luci" 2>/dev/null) || code=000
    [ "$code" != "000" ] && break
    i=$((i+1))
    if [ $i -gt 30 ]; then
        echo "FAIL: container not responding after 30s"
        docker logs "$CNAME" >&2
        exit 1
    fi
    sleep 1
done

echo "got HTTP $code"
case "$code" in
    200|302|403) echo "PASS: test_browser_container_boot";;
    *) echo "FAIL: unexpected status $code"; exit 1;;
esac
