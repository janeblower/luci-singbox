#!/bin/sh
# tests/test_route_schema_rpc.sh — dump_all() projects route_rule + rule_set with
# frontend-safe fields (depends/values/dynamic/advanced/min_version present;
# backend-only json_key/requires/coerce absent).
set -eu
cd "$(dirname "$0")/.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_route_schema_rpc (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L "$LIB" -e '
  let dump = require("builder.protocols.schema_dump").dump_all();
  let ok = (dump.route_rule != null && dump.rule_set != null);
  ok = ok && dump.route_rule.default != null && dump.route_rule.logical != null;
  ok = ok && dump.rule_set.remote != null && dump.rule_set.inline != null;
  let pf = null;
  for (let f in dump.route_rule.default.fields) if (f.name == "package_name_regex") pf = f;
  ok = ok && (pf != null && pf.min_version == "1.14" && pf.json_key == null && pf.coerce == null);
  let of = null;
  for (let f in dump.route_rule.default.fields) if (f.name == "outbound") of = f;
  ok = ok && (of != null && of.depends != null && of.requires == null && of.dynamic == "outbounds");
  print(ok ? "OK\n" : "BAD\n");
')
echo "$out"
echo "$out" | grep -q "^OK$" || { echo "FAIL"; exit 1; }
echo "test_route_schema_rpc: PASS"
