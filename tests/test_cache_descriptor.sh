#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
require("builder.settings.registry");
let reg = require("builder.protocols.registry");
let filler = require("builder._filler");
let d = reg.get("cache", "cache");
if (d == null) { print("FAIL: not registered\n"); exit(1); }
let s = { [".name"]: "cache", enabled: "1", storage: "ram", store_fakeip: "1",
          store_rdrc: "1", rdrc_timeout: "5m", cache_id: "id1" };
let out = filler.build(d, s);
if (out.enabled != true) { print("FAIL enabled\n"); exit(1); }
if (out.store_fakeip != true) { print("FAIL store_fakeip\n"); exit(1); }
if (out.store_rdrc != true) { print("FAIL store_rdrc\n"); exit(1); }
if (out.rdrc_timeout != "5m") { print("FAIL rdrc_timeout\n"); exit(1); }
if (out.cache_id != "id1") { print("FAIL cache_id\n"); exit(1); }
// storage/path are UI-only; descriptor must NOT emit them (path is added by the dispatcher, not the filler).
if ("storage" in out) { print("FAIL storage leaked\n"); exit(1); }
if ("path" in out) { print("FAIL path leaked from filler (must be dispatcher-added)\n"); exit(1); }
// disabled cache: enabled bool not set → omitted (dispatcher gate handles the real off-case).
let out2 = filler.build(d, { [".name"]: "cache", storage: "ram" });
if ("enabled" in out2) { print("FAIL: enabled emitted when unset\n"); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
