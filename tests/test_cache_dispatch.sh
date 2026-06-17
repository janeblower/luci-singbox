#!/bin/sh
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui/lib"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let cache = require("cache");
let CFG = {
  cache: { [".name"]: "cache", enabled: "1", storage: "custom", path: "/srv/c.db", store_fakeip: "1" },
  dns_server: [ { [".name"]: "f1", enabled: "1", type: "fakeip" } ],
};
let cur = {
  get_all: function(_p, t) { return CFG[t]; },
  foreach: function(_p, t, fn) { for (let s in (CFG[t] || [])) fn(s); },
};
let out = cache.build_cache(cur);
if (out.path != "/srv/c.db") { print(sprintf("FAIL path=%s\n", out.path)); exit(1); }
if (out.store_fakeip != true) { print("FAIL fakeip kept\n"); exit(1); }
// Disable the fakeip server: store_fakeip must drop.
CFG.dns_server = [ { [".name"]: "f1", enabled: "0", type: "fakeip" } ];
out = cache.build_cache(cur);
if ("store_fakeip" in out) { print("FAIL store_fakeip not gated\n"); exit(1); }
// ram storage path:
CFG.cache = { [".name"]: "cache", enabled: "1", storage: "ram" };
out = cache.build_cache(cur);
if (out.path != "/tmp/singbox-ui-cache.db") { print(sprintf("FAIL ram path=%s\n", out.path)); exit(1); }
// disabled cache → null
CFG.cache = { [".name"]: "cache", enabled: "0" };
if (cache.build_cache(cur) != null) { print("FAIL: disabled not null\n"); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
