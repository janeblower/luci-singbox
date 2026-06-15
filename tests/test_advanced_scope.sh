#!/bin/sh
# Guards Bug 4: no _show_advanced_* toggle for inbound/outbound; kept for dns/route.
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }

probe() { # $1=kind $2=type
	"$UCODE" -L "$LIB/lib" -L "$LIB" -e '
	  require("outbound"); require("inbound");
	  let d=require("builder.protocols.schema_dump"); let s=d.dump_all();
	  let m=s[ARGV[0]] ? s[ARGV[0]][ARGV[1]] : null;
	  if (!m) { print("nomat"); return; }
	  let has=false; for (let f in m.fields) if (index(f.name,"_show_advanced_")===0) has=true;
	  print(has ? "toggle" : "none");
	' "$1" "$2"
}

[ "$(probe outbound hysteria2)" = "none" ]   || { echo "FAIL: outbound still has advanced toggle"; exit 1; }
[ "$(probe inbound tproxy)" = "none" ]        || { echo "FAIL: inbound still has advanced toggle"; exit 1; }
[ "$(probe route_rule default)" = "toggle" ]  || { echo "FAIL: route_rule lost its advanced toggle"; exit 1; }
echo "PASS"
