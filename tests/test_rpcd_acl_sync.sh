#!/bin/sh
# tests/test_rpcd_acl_sync.sh
# Single-source guard: the set of methods the handler advertises (its `list`
# output) MUST equal the union of read.ubus + write.ubus in the ACL file.
# Catches the drift class test_acl_coverage.sh can't — a method added to the
# handler's METHODS table but not to the ACL file (or vice versa). Pure-ucode
# parsing (no jsonfilter/python, no grep-on-source); auto-discovered by the
# tests/run.sh glob.
set -e
cd "$(dirname "$0")/.."

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

UCODE_APP_LIB_DIR="${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
HANDLER="$PWD/luci-app-singbox-ui/root/usr/libexec/rpcd/singbox-ui"
ACL="$PWD/luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"

[ -x "$HANDLER" ] || { echo "FAIL: handler missing/not exec: $HANDLER"; exit 1; }
[ -f "$ACL" ]     || { echo "FAIL: ACL file missing: $ACL"; exit 1; }

# Methods advertised by the handler (keys of `list`, i.e. the METHODS table).
handler_methods=$("$UCODE_BIN" -L "$UCODE_APP_LIB_DIR" "$HANDLER" list 2>/dev/null \
	| "$UCODE_BIN" -e '
		let fs = require("fs");
		let d = json(fs.stdin.read("all") || "{}");
		let s = []; for (let k in d) push(s, k);
		print(join("\n", sort(s)) + "\n");
	')

# Union of read.ubus + write.ubus from the ACL file.
acl_methods=$("$UCODE_BIN" -e '
	let fs = require("fs");
	let d = json(fs.readfile("'"$ACL"'") || "{}");
	let o = d["luci-app-singbox-ui"] ?? {};
	let s = [];
	for (let k in (o.read.ubus["singbox-ui"] ?? []))  push(s, k);
	for (let k in (o.write.ubus["singbox-ui"] ?? [])) push(s, k);
	print(join("\n", sort(s)) + "\n");
')

if [ "$handler_methods" != "$acl_methods" ]; then
	echo "FAIL: handler method set != ACL read∪write"
	echo "--- handler (list keys):"
	printf "%s\n" "$handler_methods"
	echo "--- acl (read+write):"
	printf "%s\n" "$acl_methods"
	exit 1
fi
echo "PASS: rpcd handler method set matches ACL read∪write"
