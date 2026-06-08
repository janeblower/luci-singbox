#!/bin/sh
# tests/test_rpcd_handler.sh
set -e

H=luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui

if [ ! -x "$H" ]; then
  echo "FAIL: $H not present or not executable"; exit 1
fi

# Shebang invariant: rpcd invokes the handler via its shebang on the target,
# so `-L /usr/share/singbox-ui/lib` MUST be on the interpreter line. Without
# it, in-handler `require("scrub")` / `require("protocols.schema_dump")` /
# `require("reveal")` calls fail at runtime and methods like preview_config
# and protocol_schema return `require(...) failed` (regression: shebang was
# bare `#!/usr/bin/ucode` until this assertion was added). The Linux kernel
# treats everything after the interpreter as a single argv string, so the
# `-L` and its path must NOT be separated by a space — `-Lpath` form is the
# only one getopt can parse out of a shebang.
shebang_line=$(head -1 "$H")
case "$shebang_line" in
	"#!/usr/bin/ucode -L/usr/share/singbox-ui/lib")
		echo "PASS: rpcd handler shebang sets -L/usr/share/singbox-ui/lib" ;;
	*)
		echo "FAIL: rpcd handler shebang must be '#!/usr/bin/ucode -L/usr/share/singbox-ui/lib' (got: $shebang_line)"
		exit 1 ;;
esac

# Locate ucode the same way the other ucode tests do. The dev box may not have
# ucode at the OpenWrt-target path /usr/bin/ucode, so we invoke it explicitly
# through $UCODE_BIN with $UCODE_LIB_FLAGS rather than relying on the shebang
# (the shebang invariant above proves the production form is correct).
if command -v ucode >/dev/null 2>&1; then
	# Resolve to an absolute path: this test stubs `ucode` in $tmpdir via PATH
	# to spy on child invocations, and we mustn't let that stub catch the
	# top-level interpreter that's running the rpcd handler itself.
	UCODE_BIN=$(command -v ucode)
	# Handler itself does `require("scrub")` (preview_config secret-masking,
	# spec C1.2), so it needs the app's lib dir on its module search path.
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
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
for m in generate nftables restart refresh status status_detail read_config clash_get clash_mutate export_section preview_config; do
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
# Phase C2: read_config now re-serializes via sprintf("%.4J", …) after scrub,
# which inserts a space after `:` and pretty-prints. Whitespace-tolerant grep.
printf "%s\n" "$out" | jval 'd.content' | grep -Eq '"hello"[[:space:]]*:[[:space:]]*"world"' \
	|| { echo "FAIL: read_config content mismatch"; exit 1; }

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

echo "-- call clash_get proxies GET only with Bearer + path"
cat >"$tmpdir/curl" <<EOF
#!/bin/sh
echo "curl args: \$*" >> "$tmpdir/curl.log"
echo '{"connections":[],"downloadTotal":10,"uploadTotal":20}'
EOF
chmod +x "$tmpdir/curl"
: > "$tmpdir/curl.log"
out=$(echo '{"path":"/connections"}' | \
	CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
	run_h call clash_get)
printf "%s\n" "$out" | je 'd.status == "ok"' || { echo "FAIL: clash_get not ok; out=$out"; exit 1; }
body=$(printf "%s\n" "$out" | jval 'd.body')
printf "%s\n" "$body" | je 'd.downloadTotal == 10' || { echo "FAIL: body not passed through; out=$out"; exit 1; }
grep -q 'Authorization: Bearer tok' "$tmpdir/curl.log" || { echo "FAIL: Bearer not sent"; cat "$tmpdir/curl.log"; exit 1; }
grep -q '/connections' "$tmpdir/curl.log" || { echo "FAIL: path missing"; cat "$tmpdir/curl.log"; exit 1; }
grep -q -- '-X GET' "$tmpdir/curl.log" || { echo "FAIL: method not GET"; cat "$tmpdir/curl.log"; exit 1; }
echo "  PASS: clash_get proxies GET"

echo "-- call clash_get rejects method override + bad path"
# A read-ACL caller must not be able to upgrade to a write verb by stuffing
# {method:"PATCH"} into the args — clash_get must reject the field outright.
out=$(echo '{"path":"/x","method":"PATCH"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_get)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: method param should be refused; out=$out"; exit 1; }
out=$(echo '{"path":"noslash"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_get)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: bad path should error; out=$out"; exit 1; }
echo "  PASS: clash_get validates"

echo "-- call clash_mutate accepts PATCH/PUT/POST/DELETE with body"
: > "$tmpdir/curl.log"
for verb in PATCH PUT POST DELETE; do
	out=$(echo "{\"method\":\"$verb\",\"path\":\"/configs\",\"body\":\"{\\\"mode\\\":\\\"global\\\"}\"}" | \
		CLASH_CURL="$tmpdir/curl" CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok \
		run_h call clash_mutate)
	printf "%s\n" "$out" | je 'd.status == "ok"' \
		|| { echo "FAIL: $verb should be accepted; out=$out"; exit 1; }
done
grep -q -- '-X PATCH' "$tmpdir/curl.log" || { echo "FAIL: PATCH not in curl"; cat "$tmpdir/curl.log"; exit 1; }
grep -q -- '-X PUT'   "$tmpdir/curl.log" || { echo "FAIL: PUT not in curl"; cat "$tmpdir/curl.log"; exit 1; }
echo "  PASS: clash_mutate accepts write verbs"

echo "-- call clash_mutate rejects GET + missing method + bad path"
out=$(echo '{"method":"GET","path":"/x"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_mutate)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: GET should be refused on mutate; out=$out"; exit 1; }
out=$(echo '{"path":"/x"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_mutate)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: missing method should error; out=$out"; exit 1; }
out=$(echo '{"method":"PATCH","path":"noslash"}' | CLASH_CURL="$tmpdir/curl" run_h call clash_mutate)
printf "%s\n" "$out" | je 'd.status == "error"' || { echo "FAIL: bad path should error; out=$out"; exit 1; }
echo "  PASS: clash_mutate validates"

echo "-- legacy clash_request method is no longer dispatched"
# Two regressions in one shot:
#   1. `list` must NOT advertise the legacy method.
#   2. `call clash_request` must reach the default branch (status=error) — the
#      handler does not bind a case to it any more.
list_out=$(run_h list)
printf "%s\n" "$list_out" | je 'd.clash_request == null' \
	|| { echo "FAIL: list still advertises clash_request; out=$list_out"; exit 1; }
printf "%s\n" "$list_out" | je 'd.clash_get != null && d.clash_mutate != null' \
	|| { echo "FAIL: list missing clash_get/clash_mutate; out=$list_out"; exit 1; }
out=$(echo '{"method":"GET","path":"/x"}' | run_h call clash_request)
printf "%s\n" "$out" | je 'd.status == "error"' \
	|| { echo "FAIL: clash_request should error (unknown method); out=$out"; exit 1; }
echo "  PASS: clash_request removed from dispatcher"

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
	option server_password 'mysecret123'

config outbound 'out_vless'
	option enabled '1'
	option type 'vless'
	option server 'example.com'
	option server_port '443'
	option server_uuid 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

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
out_inbound=$(echo '{"kind":"inbound","name":"in_ss"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out_inbound" | je 'd.status == "ok"' \
	|| { echo "FAIL: ss inbound export should succeed; got=$out_inbound"; exit 1; }
printf "%s\n" "$out_inbound" | je 'd.section.type == "shadowsocks" && d.section.tag == "in_ss"' \
	|| { echo "FAIL: ss inbound section shape wrong; got=$out_inbound"; exit 1; }
# password is a secret — scrub_secrets masks it to "***" (see lib/scrub.uc).
printf "%s\n" "$out_inbound" | je 'd.section.listen_port == 8388 && d.section.password == "***"' \
	|| { echo "FAIL: ss inbound fields wrong; got=$out_inbound"; exit 1; }

# happy path: outbound vless
out_outbound=$(echo '{"kind":"outbound","name":"out_vless"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	run_h call export_section)
printf "%s\n" "$out_outbound" | je 'd.status == "ok"' \
	|| { echo "FAIL: vless outbound export should succeed; got=$out_outbound"; exit 1; }
printf "%s\n" "$out_outbound" | je 'd.section.type == "vless" && d.section.tag == "out_vless"' \
	|| { echo "FAIL: vless outbound section shape wrong; got=$out_outbound"; exit 1; }
printf "%s\n" "$out_outbound" | je 'd.section.server == "example.com" && d.section.server_port == 443' \
	|| { echo "FAIL: vless outbound fields wrong; got=$out_outbound"; exit 1; }

# === scrub: secrets must be masked in export_section output (C1.2) ===

# inbound shadowsocks: server_password should be "***" — not 'mysecret123'
echo "$out_inbound" | grep -q 'mysecret123' && \
	{ echo "FAIL: export_section leaked ss password"; exit 1; } || \
	echo "  PASS: export_section masks ss password"
# Both the je-parsed assertion above ("password == \"***\"") and a textual
# grep guarantee the marker reaches the wire. ucode's %J inserts spaces around
# `:` so we accept either compact or pretty form.
echo "$out_inbound" | grep -Eq '"password":[[:space:]]*"\*\*\*"' && \
	echo "  PASS: export_section emits *** marker for password" || \
	{ echo "FAIL: no mask marker in inbound output; got=$out_inbound"; exit 1; }

# outbound vless: server_uuid should be "***"
echo "$out_outbound" | grep -q 'aaaaaaaa-bbbb' && \
	{ echo "FAIL: export_section leaked vless uuid"; exit 1; } || \
	echo "  PASS: export_section masks vless uuid"
echo "$out_outbound" | grep -Eq '"uuid":[[:space:]]*"\*\*\*"' && \
	echo "  PASS: export_section emits *** marker for uuid" || \
	{ echo "FAIL: no mask marker in outbound output; got=$out_outbound"; exit 1; }

# negative: non-secret fields (server, tag, type, listen_port, etc.) must be preserved verbatim
echo "$out_outbound" | grep -Eq '"server":[[:space:]]*"\*\*\*"' && \
	{ echo "FAIL: scrub touched non-secret server field"; exit 1; } || \
	echo "  PASS: scrub leaves non-secret fields alone"

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
# Phase C2 (C2.1.9): preview_tmp now uses mktemp -p /tmp
# singbox-ui-preview.XXXXXX (atomic O_EXCL, no .json suffix), so the leak
# glob matches that pattern.
rm -f /tmp/singbox-ui-preview.*

count_preview_tmpfiles() {
	find /tmp -maxdepth 1 -name 'singbox-ui-preview.*' 2>/dev/null | wc -l
}
before_count=$(count_preview_tmpfiles)

out=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	run_h call preview_config)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config not ok; out=$out"; exit 1; }
content=$(printf "%s\n" "$out" | jval 'd.content')
# Whitespace-tolerant: preview_config re-serializes via sprintf("%.4J", …) to
# scrub secrets, which inserts a space after the colon. We just want to prove
# the key/value survived the round-trip.
printf "%s\n" "$content" | grep -Eq '"preview"[[:space:]]*:[[:space:]]*"hello"' \
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

echo "-- call preview_config scrubs secrets in the returned content"
# Stub ucode to write a config JSON containing realistic secrets, then exit 0.
# After scrub, the wire content must NOT include the secret values, MUST include
# *** markers for the known secret keys, and MUST preserve non-secret fields.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
: "${SINGBOX_CONFIG:?SINGBOX_CONFIG not set}"
cat >"$SINGBOX_CONFIG" <<'JSON'
{
  "outbounds": [
    {
      "type": "vless",
      "tag": "out-test",
      "server": "vless.example.com",
      "server_port": 443,
      "uuid": "deadbeef-1111-2222-3333-cafecafecafe",
      "password": "trojanish-secret",
      "tls": {
        "reality": {
          "public_key": "REALITY-PUB",
          "private_key": "REALITY-PRIV",
          "short_id": "abcd1234"
        }
      }
    }
  ],
  "experimental": {
    "clash_api": { "secret": "topsecret-clash" }
  }
}
JSON
exit 0
EOF
chmod +x "$tmpdir/ucode"

rm -f /tmp/singbox-ui-preview.*
out=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	run_h call preview_config)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config not ok; out=$out"; exit 1; }
content=$(printf "%s\n" "$out" | jval 'd.content')

# Negative: raw secret strings must be absent from content.
for secret in 'deadbeef-1111' 'trojanish-secret' 'REALITY-PRIV' 'REALITY-PUB' 'abcd1234' 'topsecret-clash'; do
	printf "%s\n" "$content" | grep -q "$secret" && \
		{ echo "FAIL: preview_config leaked secret '$secret'"; exit 1; }
done
echo "  PASS: preview_config strips all 6 secret values"

# Positive: *** markers must appear at the masked keys.
for k in uuid password private_key public_key short_id secret; do
	printf "%s\n" "$content" | grep -Eq "\"$k\"[[:space:]]*:[[:space:]]*\"\*\*\*\"" \
		|| { echo "FAIL: preview_config missing *** marker for $k"; exit 1; }
done
echo "  PASS: preview_config emits *** marker for every secret key"

# Non-secret fields preserved verbatim.
for keep in 'vless.example.com' 'out-test' '443'; do
	printf "%s\n" "$content" | grep -q "$keep" \
		|| { echo "FAIL: preview_config scrubbed non-secret '$keep'"; exit 1; }
done
echo "  PASS: preview_config preserves non-secret fields"

# Cleanup — same invariant as the other preview_config tests.
scrub_count=$(count_preview_tmpfiles)
[ "$scrub_count" -eq "$before_count" ] \
	|| { echo "FAIL: preview_config left a tmpfile after scrub test"; exit 1; }
echo "  PASS: preview_config scrub + cleanup"

# === C2.1.5: is_singbox_running no longer uses pgrep -f ===
echo "-- C2.1.5: is_singbox_running no longer uses pgrep -f"
grep -q 'pgrep -f "sing-box run"' luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui && \
	{ echo "FAIL: pgrep -f \"sing-box run\" still present"; exit 1; } || \
	echo "  PASS: pgrep -f \"sing-box run\" removed"

# Positive: rpcd answers status with running:true via fallback pgrep -x when
# ubus is unavailable (the test env has no ubus, so the fallback path runs).
cat >"$tmpdir/pgrep" <<'EOF'
#!/bin/sh
# Stub: only succeed for pgrep -x sing-box (the new fallback).
case "$*" in
	"-x sing-box") exit 0 ;;
	*) exit 1 ;;
esac
EOF
chmod +x "$tmpdir/pgrep"
raw=$(echo '{}' | PATH="$tmpdir:$PATH" SINGBOX_TMP=/nonexistent/path run_h call status)
printf "%s\n" "$raw" | je 'd.status == "ok" && d.running == true' \
	|| { echo "FAIL: status running=true via pgrep -x fallback; raw=[$raw]"; exit 1; }
echo "  PASS: status running=true via pgrep -x fallback"

# === C2.1.9: preview_tmp uses mktemp ===
echo "-- C2.1.9: preview_tmp uses mktemp"
grep -q 'mktemp' luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui && \
	echo "  PASS: preview_tmp uses mktemp" || \
	{ echo "FAIL: mktemp not present"; exit 1; }

# === C2 (read_config scrub gap): read_config masks secrets ===
echo "-- C2 (read_config scrub gap): read_config masks secrets"
cat >"$tmpdir/config-with-secrets.json" <<'EOF'
{
  "outbounds": [{
    "type": "vless",
    "tag": "out-rc",
    "server": "vl.example.com",
    "server_port": 443,
    "uuid": "deadbeef-7777-8888-9999-secretsecret",
    "tls": {
      "reality": {
        "public_key": "RC-PUBKEY",
        "private_key": "RC-PRIVKEY",
        "short_id": "rc-shortid"
      }
    }
  }],
  "experimental": { "clash_api": { "secret": "rc-clash-secret" } }
}
EOF
out=$(echo '{}' | SINGBOX_CONFIG="$tmpdir/config-with-secrets.json" run_h call read_config)
printf "%s\n" "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: read_config not ok; out=$out"; exit 1; }
content=$(printf "%s\n" "$out" | jval 'd.content')

# Negative: raw secrets must be absent.
for secret in 'deadbeef-7777' 'RC-PRIVKEY' 'RC-PUBKEY' 'rc-shortid' 'rc-clash-secret'; do
	printf "%s\n" "$content" | grep -q "$secret" && \
		{ echo "FAIL: read_config leaked '$secret'"; exit 1; }
done
echo "  PASS: read_config strips 5 secret values"

# Positive: *** markers + non-secret preserved.
for k in uuid private_key public_key short_id secret; do
	printf "%s\n" "$content" | grep -Eq "\"$k\"[[:space:]]*:[[:space:]]*\"\*\*\*\"" \
		|| { echo "FAIL: missing *** for $k"; exit 1; }
done
echo "  PASS: read_config emits *** markers"
for keep in 'vl.example.com' 'out-rc' '443'; do
	printf "%s\n" "$content" | grep -q "$keep" \
		|| { echo "FAIL: scrubbed non-secret '$keep'"; exit 1; }
done
echo "  PASS: read_config preserves non-secret fields"

# === D3.3: read RPCs honour reveal token ===
# Set up a shared token store in a temp path so we control its content.
reveal_tmp=$(mktemp)
trap 'rm -f "$reveal_tmp"; rm -rf "$tmpdir"' EXIT

# Helper: write a fresh valid token entry into the reveal store and echo the token.
write_valid_token() {
	tok=$(dd if=/dev/urandom bs=16 count=1 2>/dev/null | \
		ucode -e 'let fs=require("fs"); let b=fs.stdin.read(16); let s=""; for(let i=0;i<length(b);i++) s+=sprintf("%02x",ord(b,i)); print(s);')
	now_ts=$(date +%s)
	printf '{"token":"%s","issued_ts":%s,"issued_by":null}\n' "$tok" "$now_ts" >"$reveal_tmp"
	printf '%s' "$tok"
}

# Helper: write an expired token entry (issued_ts=1 → always expired).
write_expired_token() {
	printf '{"token":"abcabcabcabcabcabcabcabcabcabcab","issued_ts":1,"issued_by":null}\n' >"$reveal_tmp"
	printf 'abcabcabcabcabcabcabcabcabcabcab'
}

echo "-- D3.3: list advertises token field for read_config / export_section / preview_config"
list_out=$(run_h list)
printf '%s\n' "$list_out" | je 'd.read_config.token != null' \
	|| { echo "FAIL: list missing read_config.token; out=$list_out"; exit 1; }
printf '%s\n' "$list_out" | je 'd.export_section.token != null' \
	|| { echo "FAIL: list missing export_section.token; out=$list_out"; exit 1; }
printf '%s\n' "$list_out" | je 'd.preview_config.token != null' \
	|| { echo "FAIL: list missing preview_config.token; out=$list_out"; exit 1; }
echo "  PASS: list advertises token field"

# Shared secret config fixture.
cat >"$tmpdir/reveal-test-config.json" <<'EOF'
{
  "outbounds": [{
    "type": "vless",
    "tag": "reveal-test",
    "server": "reveal.example.com",
    "server_port": 443,
    "uuid": "11111111-2222-3333-4444-reveal-secret"
  }]
}
EOF

# --- read_config: no token → scrubbed ---
echo "-- D3.3: read_config no token → scrubbed"
out=$(printf '{}' | SINGBOX_CONFIG="$tmpdir/reveal-test-config.json" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call read_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: read_config no-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'reveal-secret' && \
	{ echo "FAIL: read_config no-token leaked secret"; exit 1; }
printf '%s\n' "$content" | grep -Eq '"uuid"[[:space:]]*:[[:space:]]*"\*\*\*"' \
	|| { echo "FAIL: read_config no-token missing *** marker"; exit 1; }
echo "  PASS: read_config no token → scrubbed"

# --- read_config: valid token → unscrubbed ---
echo "-- D3.3: read_config valid token → unscrubbed"
valid_tok=$(write_valid_token)
out=$(printf '{"token":"%s"}' "$valid_tok" | SINGBOX_CONFIG="$tmpdir/reveal-test-config.json" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call read_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: read_config valid-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'reveal-secret' \
	|| { echo "FAIL: read_config valid-token secret not present; content=$content"; exit 1; }
printf '%s\n' "$content" | grep -q '"uuid".*"\*\*\*"' && \
	{ echo "FAIL: read_config valid-token still scrubbed; content=$content"; exit 1; } || true
echo "  PASS: read_config valid token → unscrubbed"

# --- read_config: expired/garbage token → scrubbed ---
echo "-- D3.3: read_config expired token → scrubbed"
stale_tok=$(write_expired_token)
out=$(printf '{"token":"%s"}' "$stale_tok" | SINGBOX_CONFIG="$tmpdir/reveal-test-config.json" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call read_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: read_config expired-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'reveal-secret' && \
	{ echo "FAIL: read_config expired-token leaked secret"; exit 1; }
printf '%s\n' "$content" | grep -Eq '"uuid"[[:space:]]*:[[:space:]]*"\*\*\*"' \
	|| { echo "FAIL: read_config expired-token missing *** marker"; exit 1; }
echo "  PASS: read_config expired token → scrubbed"

# --- export_section: no token → scrubbed ---
echo "-- D3.3: export_section no token → scrubbed"
out=$(printf '{"kind":"inbound","name":"in_ss"}' | UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" \
	EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call export_section)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: export_section no-token not ok; out=$out"; exit 1; }
printf '%s\n' "$out" | je 'd.section.password == "***"' \
	|| { echo "FAIL: export_section no-token secret not scrubbed; out=$out"; exit 1; }
echo "  PASS: export_section no token → scrubbed"

# --- export_section: valid token → unscrubbed ---
echo "-- D3.3: export_section valid token → unscrubbed"
valid_tok=$(write_valid_token)
out=$(printf '{"kind":"inbound","name":"in_ss","token":"%s"}' "$valid_tok" | \
	UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" \
	EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call export_section)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: export_section valid-token not ok; out=$out"; exit 1; }
printf '%s\n' "$out" | je 'd.section.password == "mysecret123"' \
	|| { echo "FAIL: export_section valid-token secret still masked; out=$out"; exit 1; }
echo "  PASS: export_section valid token → unscrubbed"

# --- export_section: expired token → scrubbed ---
echo "-- D3.3: export_section expired token → scrubbed"
stale_tok=$(write_expired_token)
out=$(printf '{"kind":"inbound","name":"in_ss","token":"%s"}' "$stale_tok" | \
	UCI_CONFIG_DIR="$uci_dir" \
	UCODE_LIB="$UCODE_APP_LIB_DIR" \
	EXPORT_SECTION_UC="$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/export_section.uc" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call export_section)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: export_section expired-token not ok; out=$out"; exit 1; }
printf '%s\n' "$out" | je 'd.section.password == "***"' \
	|| { echo "FAIL: export_section expired-token secret not scrubbed; out=$out"; exit 1; }
echo "  PASS: export_section expired token → scrubbed"

# --- preview_config: no token → scrubbed ---
echo "-- D3.3: preview_config no token → scrubbed"
# Stub ucode to write a config with secrets.
cat >"$tmpdir/ucode" <<'EOF'
#!/bin/sh
: "${SINGBOX_CONFIG:?SINGBOX_CONFIG not set}"
cat >"$SINGBOX_CONFIG" <<'JSON'
{"outbounds":[{"type":"vless","tag":"prev-test","server":"prev.example.com","server_port":443,"uuid":"preview-secret-uuid"}]}
JSON
exit 0
EOF
chmod +x "$tmpdir/ucode"
out=$(printf '{}' | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call preview_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config no-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'preview-secret-uuid' && \
	{ echo "FAIL: preview_config no-token leaked secret"; exit 1; }
printf '%s\n' "$content" | grep -Eq '"uuid"[[:space:]]*:[[:space:]]*"\*\*\*"' \
	|| { echo "FAIL: preview_config no-token missing *** marker"; exit 1; }
echo "  PASS: preview_config no token → scrubbed"

# --- preview_config: valid token → unscrubbed ---
echo "-- D3.3: preview_config valid token → unscrubbed"
valid_tok=$(write_valid_token)
out=$(printf '{"token":"%s"}' "$valid_tok" | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call preview_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config valid-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'preview-secret-uuid' \
	|| { echo "FAIL: preview_config valid-token secret not present; content=$content"; exit 1; }
echo "  PASS: preview_config valid token → unscrubbed"

# --- preview_config: expired token → scrubbed ---
echo "-- D3.3: preview_config expired token → scrubbed"
stale_tok=$(write_expired_token)
out=$(printf '{"token":"%s"}' "$stale_tok" | PATH="$tmpdir:$PATH" SINGBOX_CONFIG="$real_cfg" \
	REVEAL_TOKEN_PATH="$reveal_tmp" run_h call preview_config)
printf '%s\n' "$out" | je 'd.status == "ok"' \
	|| { echo "FAIL: preview_config expired-token not ok; out=$out"; exit 1; }
content=$(printf '%s\n' "$out" | jval 'd.content')
printf '%s\n' "$content" | grep -q 'preview-secret-uuid' && \
	{ echo "FAIL: preview_config expired-token leaked secret"; exit 1; }
printf '%s\n' "$content" | grep -Eq '"uuid"[[:space:]]*:[[:space:]]*"\*\*\*"' \
	|| { echo "FAIL: preview_config expired-token missing *** marker"; exit 1; }
echo "  PASS: preview_config expired token → scrubbed"

echo "OK"
