#!/bin/sh
# tests/test_audit_g3_clash.sh
#
# Regression for GROUP G3 Clash-API findings in the rpcd handler:
#   6.2 — the Clash bearer secret must NOT appear in curl's argv (process
#         table); it goes through a 0600 tmpfile read via `-H @file`, which is
#         unlinked unconditionally after the curl call.
#   6.3 — listen/port from UCI are validated before the curl URL is built; a
#         crafted listen ("evil.com/x?") or out-of-range port falls back to the
#         loopback defaults so the request can't be redirected (SSRF/exfil).
#   6.4 — clash_mutate rejects a non-string `body` (object/number) with a clear
#         error instead of pushing a non-string token into curl argv.
#
# Runs the handler the same way as test_rpcd_handler.sh: via $UCODE_BIN -L lib
# with a curl stub on PATH that records its argv AND (for 6.2) the content +
# mode of the `-H @file` header file.
set -e
cd "$(dirname "$0")/.."

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
H="$PWD/luci-singbox-ui/root/usr/libexec/rpcd/singbox-ui"
[ -x "$H" ] || { echo "FAIL: $H not present/executable"; exit 1; }

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# je EXPR — eval ucode boolean EXPR over stdin JSON (bound as `d`).
je() {
	"$UCODE_BIN" -e '
		let fs = require("fs");
		let d;
		try { d = json(fs.stdin.read("all") || ""); } catch (e) { exit(2); }
		exit(('"$1"') ? 0 : 1);
	'
}

# curl stub: records argv to curl.log. For 6.2 it also resolves any `-H @file`
# argument and copies that header file's content + octal mode to the log dir, so
# the test can prove (a) the secret is in the file, not argv, and (b) the file is
# 0600. The stub deliberately echoes a tiny JSON body so clash_proxy emits ok.
cat >"$tmpdir/curl" <<EOF
#!/bin/sh
echo "curl args: \$*" >> "$tmpdir/curl.log"
# Find the -H @<file> argument and snapshot it before clash_proxy unlinks it.
prev=""
for a in "\$@"; do
	case "\$prev" in
		-H)
			case "\$a" in
				@*)
					f="\${a#@}"
					[ -f "\$f" ] && {
						cat "\$f" > "$tmpdir/hdrfile.content"
						# perms: stat(1) is NOT a stock busybox/OpenWrt applet, so
						# fall back to ls -l's perm column (e.g. -rw-------).
						{ stat -c '%a' "\$f" 2>/dev/null \
							|| stat -f '%Lp' "\$f" 2>/dev/null \
							|| ls -l "\$f" 2>/dev/null | awk 'NR==1{print \$1}'; } \
							> "$tmpdir/hdrfile.mode" || true
					}
					;;
				*) echo "INLINE-HEADER:\$a" >> "$tmpdir/curl.log" ;;
			esac
			;;
	esac
	prev="\$a"
done
echo '{"ok":true}'
EOF
chmod +x "$tmpdir/curl"

run_clash() {
	# \$1 = method label (get|mutate); rest piped via stdin
	_m="$1"; shift
	"$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call "$_m"
}

# ---- 6.2: secret never in argv; lands in a 0600 tmpfile via -H @file --------
: > "$tmpdir/curl.log"; rm -f "$tmpdir/hdrfile.content" "$tmpdir/hdrfile.mode"
out=$(echo '{"path":"/connections"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 \
	    CLASH_SECRET=supersecrettoken \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_get)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL(6.2): clash_get not ok; out=$out"; exit 1; }
# The secret MUST NOT be in the recorded argv.
if grep -q 'supersecrettoken' "$tmpdir/curl.log"; then
	echo "FAIL(6.2): clash secret leaked into curl argv"; cat "$tmpdir/curl.log"; exit 1
fi
# argv must reference the header by file (@...), not inline it.
grep -q -- '-H @' "$tmpdir/curl.log" \
	|| { echo "FAIL(6.2): curl not using -H @file; log:"; cat "$tmpdir/curl.log"; exit 1; }
if grep -q 'INLINE-HEADER:' "$tmpdir/curl.log"; then
	echo "FAIL(6.2): Authorization header passed inline in argv"; cat "$tmpdir/curl.log"; exit 1
fi
# The header file content held the bearer secret...
[ -f "$tmpdir/hdrfile.content" ] \
	|| { echo "FAIL(6.2): header tmpfile was not created/passed to curl"; exit 1; }
grep -q 'Authorization: Bearer supersecrettoken' "$tmpdir/hdrfile.content" \
	|| { echo "FAIL(6.2): header file lacks bearer; content=$(cat "$tmpdir/hdrfile.content")"; exit 1; }
# ...and it was mode 0600.
mode=$(cat "$tmpdir/hdrfile.mode" 2>/dev/null || echo "?")
# accept octal (stat) or the ls -l perm string (busybox fallback)
{ [ "$mode" = "600" ] || [ "$mode" = "-rw-------" ]; } \
	|| { echo "FAIL(6.2): header tmpfile mode is $mode, want 600 (-rw-------)"; exit 1; }
# And it must be unlinked after the call (the @<file> path no longer exists).
hdrpath=$(sed -n 's/.*-H @\([^ ]*\).*/\1/p' "$tmpdir/curl.log" | head -1)
[ -n "$hdrpath" ] && [ -e "$hdrpath" ] \
	&& { echo "FAIL(6.2): header tmpfile $hdrpath not unlinked after curl"; exit 1; }
echo "PASS(6.2): clash secret confined to 0600 tmpfile, absent from argv, unlinked"

# ---- 6.3: crafted listen / bad port fall back to loopback defaults ----------
: > "$tmpdir/curl.log"
out=$(echo '{"path":"/connections"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN='evil.com/x?@attacker' CLASH_PORT=99999 \
	    CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_get)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL(6.3): clash_get not ok; out=$out"; exit 1; }
# The crafted host must not survive into the URL.
if grep -q 'evil.com' "$tmpdir/curl.log"; then
	echo "FAIL(6.3): crafted listen reached curl URL"; cat "$tmpdir/curl.log"; exit 1
fi
# The out-of-range port must not survive either; loopback default URL is used.
grep -q 'http://127.0.0.1:9090/connections' "$tmpdir/curl.log" \
	|| { echo "FAIL(6.3): did not fall back to loopback default URL; log:"; cat "$tmpdir/curl.log"; exit 1; }
echo "PASS(6.3): invalid listen/port fall back to 127.0.0.1:9090"

# A VALID non-loopback listen + in-range port must be honoured (not over-clamped).
: > "$tmpdir/curl.log"
out=$(echo '{"path":"/connections"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=192.168.1.1 CLASH_PORT=8080 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_get)
grep -q 'http://192.168.1.1:8080/connections' "$tmpdir/curl.log" \
	|| { echo "FAIL(6.3): valid listen/port wrongly rewritten; log:"; cat "$tmpdir/curl.log"; exit 1; }
echo "PASS(6.3): valid listen/port preserved"

# ---- RPC-2: an IPv6 loopback ::1 listen must be ACCEPTED and bracketed --------
# Previously clash_safe_listen rejected every ':' so ::1 silently fell back to
# 127.0.0.1 — a ::1-bound Clash API was unreachable. Now ::1 is honoured and the
# URL authority brackets it: http://[::1]:9090/... (not the broken http://::1:...).
: > "$tmpdir/curl.log"
out=$(echo '{"path":"/connections"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN='::1' CLASH_PORT=9090 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_get)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL(RPC-2): clash_get with ::1 not ok; out=$out"; exit 1; }
# Must NOT fall back to 127.0.0.1.
if grep -q 'http://127.0.0.1' "$tmpdir/curl.log"; then
	echo "FAIL(RPC-2): ::1 wrongly fell back to 127.0.0.1"; cat "$tmpdir/curl.log"; exit 1
fi
# Must be bracketed: http://[::1]:9090/connections
grep -q 'http://\[::1\]:9090/connections' "$tmpdir/curl.log" \
	|| { echo "FAIL(RPC-2): ::1 listen not bracketed in URL; log:"; cat "$tmpdir/curl.log"; exit 1; }
echo "PASS(RPC-2): IPv6 ::1 listen accepted and bracketed"

# ---- 6.4: clash_mutate rejects a non-string body ----------------------------
# Object body.
out=$(echo '{"method":"PATCH","path":"/configs","body":{"mode":"global"}}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_mutate)
printf '%s\n' "$out" | je 'd.status == "error" && index(d.message, "body must be a string") >= 0' \
	|| { echo "FAIL(6.4): object body not rejected; out=$out"; exit 1; }
# Numeric body.
out=$(echo '{"method":"POST","path":"/configs","body":42}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_mutate)
printf '%s\n' "$out" | je 'd.status == "error" && index(d.message, "body must be a string") >= 0' \
	|| { echo "FAIL(6.4): numeric body not rejected; out=$out"; exit 1; }
# A real string body still works (no regression); null/absent body still works.
: > "$tmpdir/curl.log"
out=$(echo '{"method":"PATCH","path":"/configs","body":"{\"mode\":\"global\"}"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_mutate)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL(6.4): valid string body regressed; out=$out"; exit 1; }
grep -q -- '--data' "$tmpdir/curl.log" \
	|| { echo "FAIL(6.4): --data not attached for string body; log:"; cat "$tmpdir/curl.log"; exit 1; }
out=$(echo '{"method":"DELETE","path":"/connections"}' | \
	env CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	    "$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$H" call clash_mutate)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL(6.4): absent body regressed; out=$out"; exit 1; }
echo "PASS(6.4): clash_mutate rejects non-string body, keeps null/string intact"

echo "ALL PASS: tests/test_audit_g3_clash.sh"
