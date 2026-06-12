#!/bin/sh
# tests/test_protocol_users.sh — universal declarative users builder.
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_protocol_users (ucode missing)"; exit 0; }
je() { "$UCODE_BIN" -L "$LIB" -e "$1"; }
ok() { echo "  PASS: $1"; }
die() { echo "FAIL: $1 [$2]"; exit 1; }

# mixed: username:password, colon-in-password preserved, empty list -> no users
out=$(je '
    let U = require("protocols._shared.users");
    let spec = { from:"mixed_user", columns:[ {key:"username",required:true}, {key:"password",tail:true,always:true} ] };
    let r = U.build({ ".name":"m", mixed_user:["alice:secret","bob:pa:ss"] }, spec);
    print(sprintf("%J", r));
')
exp='{ "users": [ { "username": "alice", "password": "secret" }, { "username": "bob", "password": "pa:ss" } ], "from_list": true }'
[ "$out" = "$exp" ] || die "mixed users" "$out"
ok "mixed username:password (tail keeps colon)"

# vless multi + bad rows skipped (malformed uuid, missing uuid)
out=$(je '
    let U = require("protocols._shared.users");
    let spec = { from:"inbound_user", columns:[ {key:"name",required:true}, {key:"uuid",required:true,guard:"uuid"}, {key:"flow",tail:true} ] };
    let r = U.build({ ".name":"v", inbound_user:["alice:uuid-a:xtls-rprx-vision","bob:uuid-b","bad: ","carol:uuid c"] }, spec);
    print(sprintf("%J", r.users));
')
exp='[ { "name": "alice", "uuid": "uuid-a", "flow": "xtls-rprx-vision" }, { "name": "bob", "uuid": "uuid-b" } ]'
[ "$out" = "$exp" ] || die "vless multi" "$out"
ok "vless name:uuid[:flow] with bad-row skip"

# vless single fallback when list empty
out=$(je '
    let U = require("protocols._shared.users");
    let spec = { from:"inbound_user",
        columns:[ {key:"name",required:true}, {key:"uuid",required:true,guard:"uuid"}, {key:"flow",tail:true} ],
        single_fallback:{ fields:[ {key:"uuid",from:"server_uuid"}, {key:"flow",from:"vless_flow"} ] } };
    let r = U.build({ ".name":"v1", server_uuid:"11111111-1111-1111-1111-111111111111", vless_flow:"xtls-rprx-vision" }, spec);
    print(sprintf("%J", r));
')
exp='{ "users": [ { "name": "v1", "uuid": "11111111-1111-1111-1111-111111111111", "flow": "xtls-rprx-vision" } ], "from_list": false }'
[ "$out" = "$exp" ] || die "vless single fallback" "$out"
ok "vless single fallback from server_uuid"

# shadowsocks: name:method:password, method validated+discarded, empty/unknown skipped
out=$(je '
    let U = require("protocols._shared.users");
    let METHODS = ["aes-256-gcm","2022-blake3-aes-128-gcm"];
    let spec = { from:"ss_user", columns:[ {key:"name",required:true}, {key:"method",validate:METHODS,discard:true}, {key:"password",tail:true,warn_if_empty:true} ] };
    let r = U.build({ ".name":"s", ss_user:["alice:aes-256-gcm:pw","bad:nomethod:pw","eve:aes-256-gcm:"] }, spec);
    print(sprintf("%J", r.users));
')
exp='[ { "name": "alice", "password": "pw" } ]'
[ "$out" = "$exp" ] || die "ss users" "$out"
ok "shadowsocks discards method, skips unknown-method + empty-password"

# trojan single (no list)
out=$(je '
    let U = require("protocols._shared.users");
    let spec = { single_fallback:{ fields:[ {key:"password",from:"server_password"} ] } };
    let r = U.build({ ".name":"t", server_password:"pw" }, spec);
    print(sprintf("%J", r.users));
')
[ "$out" = '[ { "name": "t", "password": "pw" } ]' ] || die "trojan single" "$out"
ok "trojan single password"

echo "test_protocol_users: all PASS"
