#!/bin/sh
# tests/test_rpcd_prod_path.sh
# Production-path regression for the rpcd shebang invariant.
#
# test_rpcd_handler.sh asserts the shebang as a STRING but then runs every
# functional assert via `ucode -L <lib> <handler>` — passing -L explicitly
# and thereby BYPASSING the shebang. That cannot catch the historical bug
# where the handler shipped with a bare `#!/usr/bin/ucode` (no -L): rpcd
# launches the handler through its shebang, so in-handler require()s
# (log / protocols.schema_dump / outbound / inbound / uci / subscription_
# expand) fail and methods return errors.
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

echo "OK"
