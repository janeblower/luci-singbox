#!/bin/sh
# tests/test_sub_status.sh
# sub_status aggregates per-subscription { name, enabled, last_update, node_count }
# from UCI + the fetched sub_<name>.txt files. No network. We drive subscription.uc
# directly as a CLI subcommand (sub-status) with a fixture UCI dir + tmp dir.
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
cd "$(dirname "$0")/.."
: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

LIB="$PWD/${SB_LIB}"
SUB="$PWD/${SB_SHARE}/subscription.uc"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/uci" "$TMP/run"

cat >"$TMP/uci/singbox-ui" <<'EOF'
config outbound 'mysub'
	option type 'subscription'
	option enabled '1'
	option sub_url 'https://example/sub'

config outbound 'offsub'
	option type 'subscription'
	option enabled '0'
	option sub_url 'https://example/off'
EOF

# mysub has 2 fetched nodes; offsub has no .txt (never fetched)
printf 'vless://a\nvmess://b\n' > "$TMP/run/sub_mysub.txt"

out=$(env UCI_CONFIG_DIR="$TMP/uci" SINGBOX_TMPDIR="$TMP/run" \
	"$UCODE_BIN" -L "$LIB" "$SUB" sub-status 2>/dev/null)

# parse with ucode
val() { printf '%s' "$out" | "$UCODE_BIN" -e '
  let fs=require("fs"); let a=json(fs.stdin.read("all")||"[]");
  let want=ARGV[0], field=ARGV[1];
  for (let x in a) if (x.name===want) { print(x[field]); return; }
  print("MISSING");' "$1" "$2"; }

[ "$(val mysub node_count)" = "2" ] || { echo "FAIL: mysub node_count=$(val mysub node_count)"; echo "$out"; exit 1; }
[ "$(val mysub enabled)" = "1" ]    || { echo "FAIL: mysub enabled=$(val mysub enabled)"; exit 1; }
[ "$(val mysub last_update)" = "MISSING" ] && { echo "FAIL: mysub last_update absent"; exit 1; }
[ "$(val offsub node_count)" = "0" ] || { echo "FAIL: offsub node_count=$(val offsub node_count)"; exit 1; }
[ "$(val offsub enabled)" = "0" ]    || { echo "FAIL: offsub enabled=$(val offsub enabled)"; exit 1; }

echo "PASS: sub_status aggregates node_count/last_update/enabled"
