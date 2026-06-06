#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

# Locate ucode the same way the other ucode tests do. The handler's shebang
# (#!/usr/bin/ucode) is correct for the OpenWrt target but absent on the dev
# box, so we invoke it explicitly through $UCODE_BIN.
if command -v ucode >/dev/null 2>&1; then
	# Resolve to an absolute path: this test stubs `ucode` in $tmpdir via PATH
	# to spy on child invocations, and we mustn't let that stub catch the
	# top-level interpreter that's running the rpcd handler itself.
	UCODE_BIN=$(command -v ucode)
	UCODE_LIB_FLAGS=""
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"
	exit 0
fi

# shellcheck disable=SC2086
run_h() { "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" "$@"; }

# je EXPR — read JSON from stdin, eval ucode boolean EXPR (parsed object bound
# as `d`); exit 0 if truthy, 1 otherwise. Replaces `jq -e`.
je() {
	ucode -e '
		let fs = require("fs");
		let raw = fs.stdin.read("all") || "";
		let d;
		try { d = json(raw); } catch (e) { warn("je: invalid json\n"); exit(2); }
		exit(('"$1"') ? 0 : 1);
	'
}
# jval EXPR — print the value of ucode EXPR from stdin JSON (empty if null).
# Replaces `jq -re`.
jval() {
	ucode -e '
		let fs = require("fs");
		let d = json(fs.stdin.read("all") || "");
		let v = ('"$1"');
		print(v == null ? "" : v);
	'
}

echo "-- list emits valid JSON with all methods"
out=$(run_h list)
for m in generate nftables restart refresh status read_config clash_request export_section preview_config; do
	printf "%s\n" "$out" | je "d.$m != null" || { echo "FAIL: missing $m"; exit 1; }
done
printf "%s\n" "$out" | je 'd.nftables.action != null' || { echo "FAIL: missing nftables.action"; exit 1; }
printf "%s\n" "$out" | je 'd.refresh.what != null'    || { echo "FAIL: missing refresh.what"; exit 1; }
printf "%s\n" "$out" | je 'd.export_section.kind != null && d.export_section.name != null' \
	|| { echo "FAIL: missing export_section args"; exit 1; }

echo "-- call generate dispatches to generate.uc"
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# Stubs record argv to a sentinel file because run() redirects stdout/stderr.
cat >"$tmpdir/ucode" <<EOF
#!/bin/sh
echo "called ucode with: \$*" >> "$tmpdir/ucode.log"
echo "OK"
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call generate)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: generate did not return ok"; cat "$tmpdir/ucode.log" 2>/dev/null; exit 1; }
grep -q "generate.uc" "$tmpdir/ucode.log" || { echo "FAIL: generate.uc not invoked"; cat "$tmpdir/ucode.log" 2>/dev/null; exit 1; }

echo "-- call nftables apply dispatches to NFTABLES_CMD"
cat >"$tmpdir/nftables.sh" <<EOF
#!/bin/sh
echo "called nftables with: \$*" >> "$tmpdir/nftables.log"
EOF
chmod +x "$tmpdir/nftables.sh"
out=$(echo '{"action":"apply"}' | NFTABLES_CMD="$tmpdir/nftables.sh" run_h call nftables)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: nftables apply did not return ok"; cat "$tmpdir/nftables.log" 2>/dev/null; exit 1; }
grep -q "called nftables with: apply" "$tmpdir/nftables.log" || { echo "FAIL: nftables.sh not invoked with apply"; cat "$tmpdir/nftables.log" 2>/dev/null; exit 1; }

echo "-- call nftables with bad action returns error"
out=$(echo '{"action":"haxx"}' | NFTABLES_CMD="$tmpdir/nftables.sh" run_h call nftables)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: bad action should return error"; exit 1; }

echo "-- call restart with stubbed init.d returns ok"
out=$(echo '{}' | SINGBOX_INIT=true run_h call restart)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: restart with stub did not return ok"; exit 1; }

echo "-- call restart with failing init.d returns error"
out=$(echo '{}' | SINGBOX_INIT=false run_h call restart)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: failing restart should return error"; exit 1; }

echo "-- call read_config with missing file returns error"
out=$(echo '{}' | SINGBOX_CONFIG=/nonexistent/path run_h call read_config)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: missing config should return error"; exit 1; }

echo "-- call read_config returns file contents"
echo '{"hello":"world"}' >"$tmpdir/config.json"
out=$(echo '{}' | SINGBOX_CONFIG="$tmpdir/config.json" run_h call read_config)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: read_config should return ok"; exit 1; }
printf "%s\n" "$out" | jval 'd.content' | grep -q '"hello":"world"' || { echo "FAIL: read_config content mismatch"; exit 1; }

echo "-- call status returns ok with empty lists when tmpdir missing"
out=$(echo '{}' | SINGBOX_TMP=/nonexistent/path run_h call status)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: status should return ok"; exit 1; }
printf "%s\n" "$out" | je 'length(d.subscriptions) == 0' || { echo "FAIL: subscriptions should be empty"; exit 1; }
printf "%s\n" "$out" | je 'length(d.rulesets) == 0'      || { echo "FAIL: rulesets should be empty"; exit 1; }

echo "-- call status picks up sub_*.txt and rs_*.json"
mkdir -p "$tmpdir/state"
: >"$tmpdir/state/sub_alpha.txt"
: >"$tmpdir/state/rs_beta.json"
out=$(echo '{}' | SINGBOX_TMP="$tmpdir/state" run_h call status)
printf "%s\n" "$out" | je 'd.subscriptions[0].name == "alpha"' || { echo "FAIL: subscription alpha not found"; exit 1; }
printf "%s\n" "$out" | je 'd.rulesets[0].name == "beta"'       || { echo "FAIL: ruleset beta not found"; exit 1; }

echo "-- call status does not leak pgrep stdout (regression: corrupted JSON)"
# pgrep prints matching PIDs to stdout. is_singbox_running() must redirect that
# away or ubus parses the leading noise + JSON as garbage and bails with
# "Invalid argument". Stub pgrep to a noisy child and assert one clean line.
cat >"$tmpdir/pgrep" <<'EOF'
#!/bin/sh
echo "12345"
echo "stderr-noise" >&2
exit 0
EOF
chmod +x "$tmpdir/pgrep"
raw=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_TMP=/nonexistent/path run_h call status)
# Command substitution strips trailing newlines; a clean response is one JSON
# line, so $raw must contain no embedded newlines. A leaked PID would show up
# as a line BEFORE the JSON.
case "$raw" in
	*"
"*) echo "FAIL: status output has embedded newline (likely pgrep PID leak); raw=[$raw]"; exit 1 ;;
esac
case "$raw" in
	"{"*) ;;
	*) echo "FAIL: status output does not start with '{'; raw=[$raw]"; exit 1 ;;
esac
printf "%s\n" "$raw" | je 'd.status == "ok" && d.running == true' \
	|| { echo "FAIL: status not ok or running=true; raw=[$raw]"; exit 1; }

echo "-- call status reports running=false when pgrep finds nothing"
cat >"$tmpdir/pgrep" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$tmpdir/pgrep"
raw=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_TMP=/nonexistent/path run_h call status)
printf "%s\n" "$raw" | je 'd.running == false' \
	|| { echo "FAIL: running should be false; raw=[$raw]"; exit 1; }

echo "-- call refresh with invalid what returns error"
out=$(echo '{"what":"haxx"}' | run_h call refresh)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: invalid what should return error"; exit 1; }

echo "-- call refresh dispatches to subscription.uc"
# Replace stub from earlier in the file (which writes "OK" not invocation log).
cat >"$tmpdir/ucode" <<EOF
#!/bin/sh
echo "called ucode with: \$*" >> "$tmpdir/refresh.log"
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{"what":"all"}' | PATH="$tmpdir:$PATH" run_h call refresh)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: refresh did not return ok"; cat "$tmpdir/refresh.log" 2>/dev/null; exit 1; }
grep -q "refresh all force" "$tmpdir/refresh.log" || { echo "FAIL: subscription.uc not invoked with refresh all force"; cat "$tmpdir/refresh.log" 2>/dev/null; exit 1; }

echo "-- call with unknown method returns error"
out=$(echo '{}' | run_h call frobnicate)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: unknown method should return error"; exit 1; }

echo "-- run() redirects both stdout and stderr"
# Use a stub ucode that writes to stderr; that text must NOT appear in the
# JSON we emit. Drive a `call generate` and inspect stdout for a clean JSON.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
echo "stderr-noise" >&2
echo "stdout-noise"
exit 0
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call generate 2>/dev/null)
echo "$out" | grep -q 'stderr-noise' && { echo "FAIL: stderr leaked into response"; exit 1; }
echo "$out" | grep -q 'stdout-noise' && { echo "FAIL: stdout leaked into response"; exit 1; }
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: status not ok"; exit 1; }
echo "  PASS: stderr+stdout suppressed"

echo "-- call clash_request proxies to curl with Bearer + method + path"
cat >"$tmpdir/curl" <<EOF
#!/bin/sh
echo "curl args: \$*" >> "$tmpdir/curl.log"
echo '{"connections":[],"downloadTotal":10,"uploadTotal":20}'
EOF
chmod +x "$tmpdir/curl"
out=$(echo '{"method":"GET","path":"/connections"}' | \
	CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	run_h call clash_request)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: clash_request not ok"; echo "$out"; exit 1; }
body=$(printf "%s\n" "$out" | jval 'd.body')
printf "%s\n" "$body" | je 'd.downloadTotal == 10' || { echo "FAIL: body not passed through"; echo "$out"; exit 1; }
grep -q 'Authorization: Bearer tok' "$tmpdir/curl.log" || { echo "FAIL: Bearer secret not sent"; cat "$tmpdir/curl.log"; exit 1; }
grep -q '/connections' "$tmpdir/curl.log" || { echo "FAIL: path not in URL"; cat "$tmpdir/curl.log"; exit 1; }
echo "  PASS: clash_request proxies correctly"

echo "-- call clash_request rejects bad method / path"
out=$(echo '{"method":"FOO","path":"/x"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_request)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: bad method should error"; exit 1; }
out=$(echo '{"method":"GET","path":"noslash"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_request)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: bad path should error"; exit 1; }
echo "  PASS: clash_request validates inputs"

echo "-- call clash_request accepts PATCH (clash uses PATCH /configs)"
for verb in PATCH PUT; do
	out=$(echo "{\"method\":\"$verb\",\"path\":\"/configs\",\"body\":\"{}\"}" | \
		CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
		run_h call clash_request)
	printf "%s\n" "$out" | je 'd.status == "ok"' \
		|| { echo "FAIL: $verb should be accepted"; echo "$out"; exit 1; }
done
echo "  PASS: PATCH/PUT accepted"

echo "-- call export_section validates kind/name and proxies to helper"
# Build a tiny UCI tree with one inbound and one outbound. UCI_CONFIG_DIR is
# honoured by both the handler's helper invocation and by export_section.uc
# itself (uci.cursor reads from there).
uci_dir="$tmpdir/uci"
mkdir -p "$uci_dir"
cat >"$uci_dir/singbox-ui" <<'EOF'
config inbound 'in_ss'
	option enabled '1'
	option protocol 'shadowsocks'
	option listen '::'
	option listen_port '8388'
	option shadowsocks_method 'aes-256-gcm'
	option server_password 'pw'

config outbound 'out_vless'
	option enabled '1'
	option type 'vless'
	option server 'example.com'
	option server_port '443'
	option server_uuid '550e8400-e29b-41d4-a716-446655440000'

config outbound 'out_url'
	option enabled '1'
	option type 'url'
	option proxy_url 'vless://uuid@example.com:443'

config outbound 'out_sub'
	option enabled '1'
	option type 'subscription'
EOF

# bad kind rejected
out=$(echo '{"kind":"bogus","name":"in_ss"}' | UCI_CONFIG_DIR="$uci_dir" run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: bad kind should error; got=$out"; exit 1; }

# missing name rejected
out=$(echo '{"kind":"inbound"}' | UCI_CONFIG_DIR="$uci_dir" run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: missing name should error; got=$out"; exit 1; }

# nonexistent section rejected
out=$(echo '{"kind":"inbound","name":"nope"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: missing section should error; got=$out"; exit 1; }

# happy path: inbound shadowsocks
out=$(echo '{"kind":"inbound","name":"in_ss"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: ss inbound export should succeed; got=$out"; exit 1; }
printf "%s\n" "$out" | je 'd.section.type == "shadowsocks" && d.section.tag == "in_ss"' \
	|| { echo "FAIL: ss inbound section shape wrong; got=$out"; exit 1; }
printf "%s\n" "$out" | je 'd.section.listen_port == 8388 && d.section.password == "pw"' \
	|| { echo "FAIL: ss inbound fields wrong; got=$out"; exit 1; }

# happy path: outbound vless
out=$(echo '{"kind":"outbound","name":"out_vless"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: vless outbound export should succeed; got=$out"; exit 1; }
printf "%s\n" "$out" | je 'd.section.type == "vless" && d.section.tag == "out_vless"' \
	|| { echo "FAIL: vless outbound section shape wrong; got=$out"; exit 1; }
printf "%s\n" "$out" | je 'd.section.server == "example.com" && d.section.server_port == 443' \
	|| { echo "FAIL: vless outbound fields wrong; got=$out"; exit 1; }

# kind mismatch (querying outbound for an inbound name) returns error
out=$(echo '{"kind":"outbound","name":"in_ss"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: kind mismatch should error; got=$out"; exit 1; }

# url / subscription outbound types are refused (out of scope per spec)
for n in out_url out_sub; do
	out=$(echo "{\"kind\":\"outbound\",\"name\":\"$n\"}" | UCI_CONFIG_DIR="$uci_dir" \
		UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
		run_h call export_section)
	printf "%s\n" "$out" | je 'd.status == "error"' \
		|| { echo "FAIL: $n should be refused; got=$out"; exit 1; }
done
echo "  PASS: export_section happy path + refusals"

echo "-- call preview_config returns ok with content and cleans up tmpfile"
# Stub ucode to emulate generate.uc: write a tiny JSON blob to whatever path
# SINGBOX_CONFIG points at, then exit 0. run_env() must propagate that env.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
: "${SINGBOX_CONFIG:?SINGBOX_CONFIG not set}"
printf '{"preview":"hello"}\n' >"$SINGBOX_CONFIG"
exit 0
EOF
chmod +x "$tmpdir/ucode"

# Snapshot the real config path so we can prove preview_config did NOT
# touch it (side-effect-free is the whole point of dry-run).
real_cfg="$tmpdir/real-config.json"
echo '{"real":"untouched"}' >"$real_cfg"
real_before=$(cat "$real_cfg")

# Remove any leftover tmpfiles from previous runs so leak detection is exact.
rm -f /tmp/singbox-ui-preview.*.json

count_preview_tmpfiles() {
	find /tmp -maxdepth 1 -name 'singbox-ui-preview.*.json' 2>/dev/null | wc -l
}
before_count=$(count_preview_tmpfiles)

out=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	run_h call preview_config)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config not ok; out=$out"; exit 1; }
content=$(printf "%s\n" "$out" | jval 'd.content')
printf "%s\n" "$content" | grep -q '"preview":"hello"' \
	|| { echo "FAIL: preview content missing; out=$out"; exit 1; }
# Content must start with `{` — a valid JSON root.
case "$content" in
	"{"*) ;;
	*) echo "FAIL: preview content does not start with '{'; content=[$content]"; exit 1 ;;
esac

# Side-effect-free: the "real" config file must be untouched.
[ "$(cat "$real_cfg")" = "$real_before" ] \
	|| { echo "FAIL: preview_config mutated SINGBOX_CONFIG"; exit 1; }

# Tmpfile must be gone (preview deletes after read).
after_count=$(count_preview_tmpfiles)
[ "$after_count" -eq "$before_count" ] \
	|| { echo "FAIL: preview_config left a tmpfile behind ($before_count -> $after_count)"; exit 1; }
echo "  PASS: preview_config happy path + cleanup + side-effect-free"

echo "-- call preview_config twice in a row both succeed (tmpfile collision check)"
# Two sequential calls. Since the tmpfile name includes time() AND 4 bytes of
# /dev/urandom, even back-to-back invocations within the same second won't
# collide. Both should return ok with valid content.
out1=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" run_h call preview_config)
out2=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" run_h call preview_config)
printf "%s\n" "$out1" | je 'd.status == "ok"' \
	|| { echo "FAIL: first preview_config not ok"; exit 1; }
printf "%s\n" "$out2" | je 'd.status == "ok"' \
	|| { echo "FAIL: second preview_config not ok"; exit 1; }
# Both runs must leave a clean tmpdir.
end_count=$(count_preview_tmpfiles)
[ "$end_count" -eq "$before_count" ] \
	|| { echo "FAIL: preview_config tmpfile not cleaned after two calls"; exit 1; }
echo "  PASS: two sequential preview_config calls"

echo "-- call preview_config returns error when generate fails"
# Stub ucode to exit non-zero without writing anything. The handler must
# return error AND not leave the tmpfile behind.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
exit 7
EOF
chmod +x "$tmpdir/ucode"
out=$(echo '{}' | PATH="$tmpdir:$PATH" run_h call preview_config)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: preview_config should error when generate fails; out=$out"; exit 1; }
fail_count=$(count_preview_tmpfiles)
[ "$fail_count" -eq "$before_count" ] \
	|| { echo "FAIL: preview_config left a tmpfile after generate failure"; exit 1; }
echo "  PASS: preview_config error path + cleanup"

echo "OK"
