#!/bin/sh
# tests/test_protocol_descriptors.sh
# Tests for lib/protocols/registry.uc + lib/protocols/ssh.uc — C3 descriptor
# foundation. Registry contract (register/get/types_for_kind), ssh descriptor
# is registered, and emit() produces the expected sing-box outbound shape.
set -e
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode; UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else echo "SKIP: ucode not available"; exit 0; fi

# Test 1: registry register + get + types_for_kind
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let reg = require("protocols.registry");
	reg.register({ kind: "outbound", type: "test_p", emit: function(s){return {type: "test_p"}} });
	let d = reg.get("outbound", "test_p");
	print(d.type);
	print("\n");
	print(length(reg.types_for_kind("outbound")) >= 1 ? "ok" : "no");
')
case "$out" in
	"test_p"*"ok") echo "PASS: registry register/get/types_for_kind" ;;
	*) echo "FAIL: registry contract: [$out]"; exit 1 ;;
esac

# Test 2: ssh descriptor is registered (after require("protocols.ssh"))
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	require("protocols.ssh");
	let reg = require("protocols.registry");
	let d = reg.get("outbound", "ssh");
	print(d == null ? "missing" : d.sing_box_type);
	print("|");
	print(d == null ? "0" : sprintf("%d", length(d.fields)));
')
case "$out" in
	"ssh|6") echo "PASS: ssh descriptor present with 6 fields" ;;
	*) echo "FAIL: ssh descriptor: [$out]"; exit 1 ;;
esac

# Test 3: ssh descriptor emit() shape — required + optional fields
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	require("protocols.ssh");
	let reg = require("protocols.registry");
	let d = reg.get("outbound", "ssh");
	let r = d.emit({ [".name"]: "myssh", server: "1.2.3.4", server_port: "2222", user: "alice", password: "secret" });
	print(sprintf("%s|%s|%s|%d|%s|%s", r.type, r.tag, r.server, r.server_port, r.user, r.password));
')
case "$out" in
	"ssh|myssh|1.2.3.4|2222|alice|secret") echo "PASS: ssh emit shape" ;;
	*) echo "FAIL: ssh emit: [$out]"; exit 1 ;;
esac

# Test 4: ssh emit() defaults server_port to 22 when missing
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	require("protocols.ssh");
	let reg = require("protocols.registry");
	let d = reg.get("outbound", "ssh");
	let r = d.emit({ [".name"]: "x", server: "h", user: "u" });
	print(sprintf("%d|%s", r.server_port, r.password == null ? "nopwd" : r.password));
')
case "$out" in
	"22|nopwd") echo "PASS: ssh emit defaults" ;;
	*) echo "FAIL: ssh defaults: [$out]"; exit 1 ;;
esac

# Test 5: ssh emit() includes host_key when it is a non-empty list
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	require("protocols.ssh");
	let reg = require("protocols.registry");
	let d = reg.get("outbound", "ssh");
	let r = d.emit({ [".name"]: "x", server: "h", user: "u", host_key: ["ssh-ed25519 AAAA..."] });
	print(type(r.host_key));
	print("|");
	print(length(r.host_key));
')
case "$out" in
	"array|1") echo "PASS: ssh emit host_key passthrough" ;;
	*) echo "FAIL: ssh host_key: [$out]"; exit 1 ;;
esac

# Test 6: outbound.uc dispatcher consults registry FIRST and returns
# descriptor's emit() output (proves the wire-up in lib/outbound.uc works).
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let ob = require("outbound");
	let r = ob.build_constructor_for({ [".name"]: "myssh", server: "1.2.3.4", server_port: "22", user: "alice" }, "ssh");
	print(sprintf("%s|%s|%s|%d|%s", r.type, r.tag, r.server, r.server_port, r.user));
')
case "$out" in
	"ssh|myssh|1.2.3.4|22|alice") echo "PASS: dispatcher routes ssh to descriptor" ;;
	*) echo "FAIL: dispatcher: [$out]"; exit 1 ;;
esac

# Test 7: dispatcher falls through to legacy switch for non-registered types
# (vless has no descriptor; should still build via legacy code path).
# shellcheck disable=SC2086
out=$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let ob = require("outbound");
	let r = ob.build_constructor_for({ [".name"]: "v1", server: "1.2.3.4", server_port: "443", server_uuid: "u-u-i-d" }, "vless");
	print(sprintf("%s|%s|%s", r.type, r.server, r.uuid));
')
case "$out" in
	"vless|1.2.3.4|u-u-i-d") echo "PASS: dispatcher falls through to legacy for vless" ;;
	*) echo "FAIL: legacy fallthrough: [$out]"; exit 1 ;;
esac
