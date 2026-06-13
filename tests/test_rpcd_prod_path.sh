#!/bin/sh
# tests/test_rpcd_prod_path.sh
# Production-path regression for the rpcd shebang invariant.
#
# test_rpcd_handler.sh asserts the shebang as a STRING but then runs every
# functional assert via `ucode -L <lib> <handler>` — passing -L explicitly
# and thereby BYPASSING the shebang. That cannot catch the historical bug
# where the handler shipped with a bare `#!/usr/bin/ucode` (no -L): rpcd
# launches the handler through its shebang, so in-handler require()s
# (log / protocols.schema_dump / outbound / inbound / uci) fail and methods return errors.
#
# This test installs the handler + lib into the guest's REAL system paths,
# restarts rpcd, and calls `ubus call singbox-ui ...`. rpcd execs the
# handler via its shebang exactly as production does, so a regressed
# shebang makes status/list error out and this test goes red.
set -e
cd "$(dirname "$0")/.."

# Only meaningful inside the OpenWrt qemu VM, where a live rpcd + ubus
# exist. On a plain host (and in the host-only subset) there is no ubus to
# talk to, so SKIP — the string-form shebang assert in test_rpcd_handler.sh
# still runs everywhere.
if [ "${SINGBOX_TESTS_IN_VM:-0}" != "1" ]; then
	echo "SKIP test_rpcd_prod_path: needs a live rpcd/ubus (VM only)"
	exit 0
fi
command -v ubus >/dev/null 2>&1 || { echo "SKIP: no ubus in this env"; exit 0; }
command -v rpcd >/dev/null 2>&1 || { echo "SKIP: no rpcd in this env"; exit 0; }

SRC=luci-singbox-ui/root
HANDLER_SRC="$SRC/usr/libexec/rpcd/singbox-ui"
LIB_SRC="$SRC/usr/share/singbox-ui/lib"
ACL_SRC="$SRC/usr/share/rpcd/acl.d/luci-singbox-ui.json"

[ -x "$HANDLER_SRC" ] || { echo "FAIL: $HANDLER_SRC not executable"; exit 1; }
[ -d "$LIB_SRC" ]     || { echo "FAIL: $LIB_SRC missing"; exit 1; }

# Install into the real system paths the shebang hard-codes. We copy the
# WHOLE app tree the handler needs at runtime (lib + the *.uc entrypoints
# under /usr/share/singbox-ui) so requires + child execs resolve exactly
# as on a packaged device.
mkdir -p /usr/libexec/rpcd /usr/share/singbox-ui /usr/share/rpcd/acl.d
cp -f "$HANDLER_SRC" /usr/libexec/rpcd/singbox-ui
chmod +x /usr/libexec/rpcd/singbox-ui
cp -af "$SRC/usr/share/singbox-ui/." /usr/share/singbox-ui/
cp -f "$ACL_SRC" /usr/share/rpcd/acl.d/luci-singbox-ui.json

# Restart rpcd so it re-scans /usr/libexec/rpcd and registers the object,
# launching the handler via its shebang the next time a method is called.
/etc/init.d/rpcd restart
# Give rpcd a moment to settle before the first call (mirrors
# test_browser.sh:99 which sleeps after an rpcd reload).
i=0; while [ $i -lt 10 ]; do
	ubus list 2>/dev/null | grep -q '^singbox-ui$' && break
	i=$((i + 1)); sleep 1
done
ubus list 2>/dev/null | grep -q '^singbox-ui$' \
	|| { echo "FAIL: rpcd did not register the 'singbox-ui' ubus object"; exit 1; }
echo "  PASS: singbox-ui ubus object registered via rpcd"

# 1) `status` must succeed through the shebang path. is_singbox_running()
#    + list_files_with_mtime() only use the fs/ubus builtins, but a broken
#    shebang would still make the handler fail to load at all, so a clean
#    {"status":"ok",...} proves the interpreter launched correctly.
out=$(ubus call singbox-ui status 2>/dev/null) \
	|| { echo "FAIL: 'ubus call singbox-ui status' returned non-zero (shebang/require regressed?)"; exit 1; }
echo "$out" | grep -q '"status": *"ok"' \
	|| { echo "FAIL: status did not return ok via prod path; out=$out"; exit 1; }
echo "  PASS: ubus call singbox-ui status ok via shebang path"

# 2) `protocol_schema` is the canonical require()-heavy method: it loads
#    protocols.schema_dump + outbound + inbound. If -L is missing from the
#    shebang these requires fail and the method returns
#    {"status":"error","message":"require(...) failed"}. This is the exact
#    bug class the regression guards.
out=$(ubus call singbox-ui protocol_schema 2>/dev/null) \
	|| { echo "FAIL: 'ubus call singbox-ui protocol_schema' returned non-zero"; exit 1; }
echo "$out" | grep -q '"status": *"ok"' \
	|| { echo "FAIL: protocol_schema errored via prod path (shebang -L missing?); out=$out"; exit 1; }
echo "$out" | grep -q 'require' && echo "$out" | grep -q '"error"' \
	&& { echo "FAIL: protocol_schema hit a require() failure via prod path; out=$out"; exit 1; }
echo "  PASS: ubus call singbox-ui protocol_schema loads lib modules via -L shebang"

# 3) `list` over ubus must advertise the methods. rpcd calls the handler's
#    `list` to learn the signatures; `ubus -v list <obj>` prints them. NB: `-v`
#    is a GLOBAL option and must precede the command — `ubus list -v <obj>` is
#    rejected with a usage error (verified on the live box), so the arg order
#    here is load-bearing. A populated method list proves rpcd parsed the
#    handler's emit_list() output through the shebang.
ubus -v list singbox-ui 2>/dev/null | grep -q '"status"' \
	|| { echo "FAIL: ubus does not advertise singbox-ui methods; rpcd failed to parse handler list"; exit 1; }
echo "  PASS: rpcd parsed handler method list via shebang"

# 4) Extra method coverage through the REAL ubus prod-path (audit 10.4).
#    Only 3 reference methods (status/protocol_schema/list) used to be called
#    here; the bulk of the require()/fork chain lived only in
#    test_rpcd_handler.sh, which runs the handler via `ucode -L <handler>` and
#    thereby BYPASSES the shebang. Methods that require()-chain or read files
#    at call time can regress in ways only the prod path surfaces (argv/env/cwd
#    differences under rpcd). We exercise the require-heavy / fork-heavy /
#    file-reading ones over `ubus call` so the shebang+require+child-exec path
#    is validated for them too.
#
# Helper: call a method, assert the handler launched (non-zero rc == the
# interpreter never came up, the exact shebang-regression symptom) and that the
# JSON body is parseable and free of a require()-failure marker. We deliberately
# do NOT require status:"ok" for every method — e.g. read_config legitimately
# returns status:"error","config not generated yet" on a box that has not run
# generate — but it must still return a CLEAN JSON envelope, never a
# require(...) failed / interpreter crash.
assert_clean() {
	_m="$1"; _out="$2"
	# A require() failure surfaces as an error envelope whose message contains
	# the literal marker `require(<module>) failed`. Match `require(` (not the
	# bare word "require") so a future CLEAN status:"error" message that merely
	# contains "require"/"required" (e.g. a "field is required" validation
	# error) cannot false-FAIL this assertion.
	if printf '%s' "$_out" | grep -q 'require(' && printf '%s' "$_out" | grep -q '"error"'; then
		echo "FAIL: $_m hit a require() failure via prod path; out=$_out"; exit 1
	fi
	# Must be a JSON object envelope with a status field (proves the handler
	# emitted, i.e. the shebang launched and the dispatcher ran).
	printf '%s' "$_out" | grep -q '"status"' \
		|| { echo "FAIL: $_m did not return a JSON status envelope via prod path; out=$_out"; exit 1; }
}

# 4a) read_config — opens /tmp/singbox-ui.json with fs builtins. Either
#     status:ok (config present) or status:error (not generated yet); both are
#     CLEAN. A broken shebang would make even this fail to launch.
out=$(ubus call singbox-ui read_config 2>/dev/null) \
	|| { echo "FAIL: 'ubus call singbox-ui read_config' returned non-zero (shebang/require regressed?)"; exit 1; }
assert_clean read_config "$out"
echo "  PASS: ubus call singbox-ui read_config returns a clean JSON envelope"

# 4c) export_section — FORKS export_section.uc (a child ucode process that
#     itself require()s lib/ via its own shebang). This is the fork+child-exec
#     chain no direct `ucode -L handler` test can cover. An unknown section
#     returns a clean error envelope.
out=$(ubus call singbox-ui export_section '{"kind":"outbound","name":"nonexistent_out"}' 2>/dev/null) \
	|| { echo "FAIL: 'ubus call singbox-ui export_section' returned non-zero"; exit 1; }
assert_clean export_section "$out"
echo "  PASS: ubus call singbox-ui export_section forks helper via shebang"

# 4d) bbolt_status — read-only fs.stat + host_arch() (forks `apk --print-arch`).
#     Always status:ok; installed:true/false depending on the box.
out=$(ubus call singbox-ui bbolt_status 2>/dev/null) \
	|| { echo "FAIL: 'ubus call singbox-ui bbolt_status' returned non-zero"; exit 1; }
assert_clean bbolt_status "$out"
printf '%s' "$out" | grep -q '"status": *"ok"' \
	|| { echo "FAIL: bbolt_status did not return ok via prod path; out=$out"; exit 1; }
echo "  PASS: ubus call singbox-ui bbolt_status ok via shebang path"

echo "OK"
