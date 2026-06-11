#!/bin/sh
# tests/test_protocol_schema_rpc.sh
# Validates singbox-ui::protocol_schema RPC: status ok, all expected protocols
# present, no emit/function leak, secret flag preserved.
set -e
cd "$(dirname "$0")/.."

H=luci-singbox-ui/root/usr/libexec/rpcd/singbox-ui

if [ ! -x "$H" ]; then
	echo "FAIL: $H not present or not executable"; exit 1
fi

# Locate ucode the same way the other ucode tests do. The handler's shebang
# (#!/usr/bin/ucode) is correct for the OpenWrt target but absent on the dev
# box, so we invoke it explicitly through $UCODE_BIN.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=$(command -v ucode)
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP test_protocol_schema_rpc (ucode missing)"
	exit 0
fi

# shellcheck disable=SC2086
run_h() { "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" "$@"; }

# je EXPR — read JSON from stdin, eval ucode boolean EXPR (parsed object bound
# as `d`); exit 0 if truthy, 1 otherwise.
je() {
	"$UCODE_BIN" -e '
		let fs = require("fs");
		let raw = fs.stdin.read("all") || "";
		let d;
		try { d = json(raw); } catch (e) { warn("je: invalid json\n"); exit(2); }
		exit(('"$1"') ? 0 : 1);
	'
}

echo "-- invoke protocol_schema"
# The handler reads args from stdin (empty JSON object for no-arg methods).
# shellcheck disable=SC2086
response=$(printf '{}' | "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" call protocol_schema 2>&1) || {
	echo "FAIL rpcd invocation failed:"; echo "$response"; exit 1; }

# 1. status ok
if ! printf '%s\n' "$response" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
	echo "FAIL response not ok:"; echo "$response"; exit 1
fi
echo "PASS protocol_schema status ok"

# 2. version:1 + schema key
if ! printf '%s\n' "$response" | grep -q '"version"[[:space:]]*:[[:space:]]*1'; then
	echo "FAIL no version=1 in response:"; echo "$response"; exit 1
fi
if ! printf '%s\n' "$response" | grep -q '"schema"'; then
	echo "FAIL no schema key in response:"; echo "$response"; exit 1
fi
echo "PASS version:1 + schema present"

# 3. All 5 outbound protocols present somewhere in response
for proto in direct shadowsocks vless trojan hysteria2; do
	if ! printf '%s\n' "$response" | grep -q "\"$proto\""; then
		echo "FAIL missing protocol name in response: $proto"; exit 1
	fi
done
echo "PASS all 5 outbound protocol names present"

# 4. Inbound protocols present within schema.inbound (ucode-parsed check)
for proto in direct tproxy mixed shadowsocks vless trojan hysteria2; do
	ok=$(printf '%s\n' "$response" | "$UCODE_BIN" -e '
		let fs = require("fs");
		let raw = fs.stdin.read("all") || "";
		let j;
		try { j = json(raw); } catch (_) { print("FAIL_PARSE\n"); exit(0); }
		if (j == null || j.schema == null || j.schema.inbound == null) {
			print("FAIL_NO_INBOUND\n"); exit(0);
		}
		if (j.schema.inbound["'"$proto"'"] == null) {
			print("FAIL_MISSING\n"); exit(0);
		}
		print("OK\n");
	')
	if [ "$ok" != "OK" ]; then
		echo "FAIL inbound.$proto not found ($ok):"; echo "$response"; exit 1
	fi
done
echo "PASS all 7 inbound descriptors present"

# 4b. Every protocol entry in schema has tabs[] array (structural assertion)
tabs_check=$(printf '%s\n' "$response" | "$UCODE_BIN" -e '
	let fs = require("fs");
	let raw = fs.stdin.read("all") || "";
	let j;
	try { j = json(raw); } catch (_) { print("FAIL_PARSE\n"); exit(0); }
	if (j == null || j.schema == null) { print("FAIL_NO_SCHEMA\n"); exit(0); }
	let bad = [];
	for (let kind in ["outbound", "inbound"]) {
		let section = j.schema[kind];
		if (section == null) continue;
		for (let name in keys(section)) {
			let entry = section[name];
			if (type(entry.tabs) !== "array") push(bad, kind + "." + name);
		}
	}
	if (length(bad)) {
		print("FAIL_NO_TABS: " + join(",", bad) + "\n");
	} else {
		print("OK\n");
	}
')
if [ "$tabs_check" != "OK" ]; then
	echo "FAIL tabs[] structural assertion: $tabs_check"; exit 1
fi
echo "PASS every schema entry has tabs[] array"

# 5. No occurrence of the literal word "function" (case-insensitive)
# Emit functions must have been stripped by schema_dump's whitelist projection.
if printf '%s\n' "$response" | grep -qi 'function'; then
	echo "FAIL response contains 'function' — emit leaked?"; exit 1
fi
echo "PASS no function leak"

# 6. At least one "secret":true preserved (proves the secret flag survived projection)
if ! printf '%s\n' "$response" | grep -q '"secret"[[:space:]]*:[[:space:]]*true'; then
	echo "FAIL no secret:true marker — projection broke?"; exit 1
fi
echo "PASS secret flag preserved"

# 7. No "emit" key in the response
if printf '%s\n' "$response" | grep -q '"emit"'; then
	echo "FAIL response contains emit key"; exit 1
fi
echo "PASS no emit key"

# 8. Dynamic selector sources survive whitelist projection (detour /
#    bind_interface → "outbounds"/"interfaces" — proves schema_dump carries
#    the `dynamic` key through to the frontend renderer).
if ! printf '%s\n' "$response" | grep -q '"dynamic"[[:space:]]*:[[:space:]]*"outbounds"'; then
	echo "FAIL no dynamic:outbounds marker — schema_dump whitelist missing 'dynamic'?"; exit 1
fi
echo "PASS dynamic selector source preserved"

# 9. tproxy.interface is a persisted dynamic device selector, NOT a virtual
#    (write-suppressed) field — regression guard for the de-virtualization fix.
itf=$(printf '%s\n' "$response" | "$UCODE_BIN" -e '
	let fs = require("fs");
	let raw = fs.stdin.read("all") || "";
	let j; try { j = json(raw); } catch (_) { print("FAIL_PARSE\n"); exit(0); }
	let tp = (j && j.schema && j.schema.inbound) ? j.schema.inbound.tproxy : null;
	if (tp == null) { print("FAIL_NO_TPROXY\n"); exit(0); }
	let itf = null;
	for (let f in tp.fields) if (f.name == "interface") itf = f;
	if (itf == null)            { print("FAIL_NO_IFACE\n"); exit(0); }
	if (itf.virtual != null)    { print("FAIL_STILL_VIRTUAL\n"); exit(0); }
	if (itf.dynamic != "devices") { print("FAIL_NOT_DEVICES\n"); exit(0); }
	print("OK\n");
')
[ "$itf" = "OK" ] || { echo "FAIL tproxy.interface selector ($itf)"; exit 1; }
echo "PASS tproxy.interface is a de-virtualized device selector"

echo "PASS test_protocol_schema_rpc"
