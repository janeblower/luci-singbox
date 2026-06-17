#!/bin/sh
# tests/test_clash_delay.sh
# clash_delay builds /proxies/<name>/delay?url=...&timeout=... on the server,
# percent-encoding an arbitrary (unicode/space-bearing) proxy name and the test
# url, with a numeric timeout. The generic clash_path_ok allowlist rejects query
# strings, so this path is built+validated by call_clash_delay itself. We stub
# CLASH_CURL with a script that echoes the URL it was handed, so the handler's
# {status:"ok",body:<url>} lets us assert the exact constructed URL.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
HANDLER="$PWD/${SB_RPCD}"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# curl stub: print the LAST argv element (clash_proxy puts the URL last).
cat >"$TMP/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do last="$a"; done
printf '%s' "$last"
EOF
chmod +x "$TMP/curl"

call() { # $1 = JSON args
  printf '%s' "$1" | env CLASH_CURL="$TMP/curl" CLASH_LISTEN="127.0.0.1" \
    CLASH_PORT="9090" CLASH_SECRET="" \
    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call clash_delay 2>/dev/null
}
body() { printf '%s' "$1" | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.body ?? "");'; }
status() { printf '%s' "$1" | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.status ?? "");'; }

# advertised in list
"$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" list 2>/dev/null | grep -q 'clash_delay' \
  || { echo "FAIL: clash_delay not advertised"; exit 1; }

# 1) unicode + space name, default url, default timeout
out=$(call '{"name":"🇺🇸 US-1"}')
url=$(body "$out")
want='http://127.0.0.1:9090/proxies/%F0%9F%87%BA%F0%9F%87%B8%20US-1/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000'
[ "$url" = "$want" ] || { echo "FAIL: encoded url mismatch"; echo " got:  $url"; echo " want: $want"; exit 1; }

# 2) custom timeout is honored and clamped to integer
out=$(call '{"name":"a","timeout":"3000"}')
case "$(body "$out")" in *"&timeout=3000") : ;; *) echo "FAIL: timeout not honored: $(body "$out")"; exit 1;; esac

# 3) out-of-range / non-numeric timeout falls back to 5000
out=$(call '{"name":"a","timeout":"abc"}')
case "$(body "$out")" in *"&timeout=5000") : ;; *) echo "FAIL: bad timeout not defaulted: $(body "$out")"; exit 1;; esac

# 4) invalid url scheme rejected
out=$(call '{"name":"a","url":"ftp://evil/x"}')
[ "$(status "$out")" = "error" ] || { echo "FAIL: non-http url accepted: $out"; exit 1; }

# 5) empty name rejected
out=$(call '{"name":""}')
[ "$(status "$out")" = "error" ] || { echo "FAIL: empty name accepted: $out"; exit 1; }

# 6) CR/LF in name are dropped (no header/curl injection), still ok status
out=$(call '{"name":"a\r\nX"}')
[ "$(status "$out")" = "ok" ] || { echo "FAIL: CRLF name errored unexpectedly: $out"; exit 1; }
case "$(body "$out")" in *"%0D%0A"*) echo "FAIL: CR/LF leaked into url: $(body "$out")"; exit 1;; esac

# --- RPC-1: curl's `-m` deadline must COVER the probe timeout, never cut it ---
# Previously clash_proxy hardcoded `-m 5`, so a probe asking for >5 s was killed
# by curl at 5 s and always reported a failure. The handler now derives curl's
# -m (whole seconds) from the probe `timeout` (ms) + ~2 s slack, clamped to 65 s.
# A second curl stub records its full argv so we can read back the -m value.
cat >"$TMP/curl_argv" <<'EOF'
#!/bin/sh
# Print the -m value: scan argv for the token right after "-m".
prev=""; for a in "$@"; do [ "$prev" = "-m" ] && { printf '%s' "$a"; exit 0; }; prev="$a"; done
EOF
chmod +x "$TMP/curl_argv"
call_m() { # $1 = JSON args -> prints the curl -m value the handler chose
  printf '%s' "$1" | env CLASH_CURL="$TMP/curl_argv" CLASH_LISTEN="127.0.0.1" \
    CLASH_PORT="9090" CLASH_SECRET="" \
    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" call clash_delay 2>/dev/null \
  | "$UCODE_BIN" -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.body ?? "");'
}
# default 5000 ms probe -> -m >= 5 (was exactly 5 before; now 5/1000 ceil + 2 = 7)
m=$(call_m '{"name":"a"}')
[ -n "$m" ] && [ "$m" -ge 5 ] || { echo "FAIL(RPC-1): default probe gave -m=$m, want >=5"; exit 1; }
# 10000 ms probe MUST get a curl -m > 5 (the old bug capped at 5)
m=$(call_m '{"name":"a","timeout":"10000"}')
[ -n "$m" ] && [ "$m" -gt 5 ] || { echo "FAIL(RPC-1): 10s probe still capped at -m=$m (<=5)"; exit 1; }
[ "$m" -ge 12 ] || { echo "FAIL(RPC-1): 10s probe -m=$m does not cover the 10s deadline"; exit 1; }
# Max 60000 ms probe -> curl -m clamped to <= 65 (no runaway hang)
m=$(call_m '{"name":"a","timeout":"60000"}')
[ -n "$m" ] && [ "$m" -le 65 ] || { echo "FAIL(RPC-1): 60s probe -m=$m exceeds 65s clamp"; exit 1; }
echo "PASS(RPC-1): curl -m deadline scales with probe timeout, clamped to 65s"

echo "PASS: clash_delay builds/validates the delay URL"
