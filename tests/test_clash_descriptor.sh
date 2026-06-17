#!/bin/sh
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui/lib"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
require("builder.settings.registry");
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let d = reg.get("clash_api", "clash_api");
if (d == null) { print("FAIL: not registered\n"); exit(1); }
let s = { [".name"]: "clash_api", enabled: "1", listen: "::1", port: "9090",
          secret: "tok", external_ui: "/www/ui", default_mode: "rule",
          access_control_allow_private_network: "1" };
let out = filler.build(d, s);
if (out.external_controller != "[::1]:9090") { print(sprintf("FAIL ec=%s\n", out.external_controller)); exit(1); }
if (out.secret != "tok") { print("FAIL secret\n"); exit(1); }
if (out.external_ui != "/www/ui") { print("FAIL external_ui\n"); exit(1); }
if (out.default_mode != "rule") { print("FAIL default_mode\n"); exit(1); }
if (out.access_control_allow_private_network != true) { print("FAIL acapn\n"); exit(1); }
if ("enabled" in out) { print("FAIL: enabled leaked to JSON\n"); exit(1); }
if ("listen" in out || "port" in out) { print("FAIL: listen/port leaked to JSON\n"); exit(1); }
// IPv4 listen → no brackets.
let out2 = filler.build(d, { [".name"]: "clash_api", enabled: "1", listen: "127.0.0.1", port: "9090" });
if (out2.external_controller != "127.0.0.1:9090") { print(sprintf("FAIL ec4=%s\n", out2.external_controller)); exit(1); }
// Pre-bracketed IPv6 listen → must NOT double-bracket.
let out3 = filler.build(d, { [".name"]: "clash_api", enabled: "1", listen: "[::1]", port: "9090" });
if (out3.external_controller != "[::1]:9090") { print(sprintf("FAIL ec_bracketed=%s\n", out3.external_controller)); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
