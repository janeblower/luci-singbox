#!/bin/sh
# tests/backend/test_parity_coverage_guard.sh — hard gate: every declared
# json_key (descriptor fields + groups + shared-block emit_spec + *_action
# fields) and every emit-only descriptor must have golden coverage under
# tests/parity/golden/. Minus the documented coverage_allowlist.txt.
set -eu
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."
UCODE_BIN="${UCODE_BIN:-ucode}"
LIB="${UCODE_LIB_DIR:-${SB_LIB}}"
command -v "$UCODE_BIN" >/dev/null 2>&1 || { echo "SKIP test_parity_coverage_guard (ucode missing)"; exit 0; }

out=$("$UCODE_BIN" -L tests/parity -L "$LIB" -e '
  let fs    = require("fs");
  let canon = require("canon").canon;
  let reg   = require("builder.protocols.registry");
  require("builder.protocols.schema_dump").dump_all();  // eager-loads all registries

  // ---- 1. collect every declared json_key across all descriptors ----
  let declared = {};   // json_key leaf -> 1
  let emit_only = {};   // "<kind>:<type>" -> 1  (hand-written emit(), no json_key)

  function leaf(jk) { let p = split(jk, "."); return p[length(p)-1]; }
  function note(jk) { if (jk != null) declared[leaf(jk)] = 1; }

  // recurse a declarative emit_spec sequence / groups
  function walk_seq(seq) {
    for (let e in (seq || [])) {
      if (e.json_key != null) note(e.json_key);
      if (e.fields != null) walk_seq(e.fields);
    }
  }
  function walk_groups(groups) {
    for (let g in (groups || [])) { note(g.json_key); walk_seq(g.fields); }
  }

  // 1a. descriptor own fields + groups + emit-only marker
  let kinds = [ "outbound", "inbound", "dns", "route_rule", "rule_set",
                "dns_rule", "cache", "clash_api" ];
  for (let k in kinds)
    for (let t in reg.types_for_kind(k)) {
      let d = reg._registry[sprintf("%s:%s", k, t)];
      if (d == null) continue;
      let has_jk = false;
      for (let f in (d.fields || [])) if (f.json_key != null) { note(f.json_key); has_jk = true; }
      if (d.groups != null) { walk_groups(d.groups); has_jk = true; }
      if (d.users != null) { for (let c in (d.users.columns || [])) { declared[c.key] = 1; has_jk = true; } }
      // hand-written emit() with no declarative json_key -> require a dedicated golden by name
      if (type(d.emit) === "function" && !has_jk) emit_only[sprintf("%s:%s", k, t)] = 1;
    }

  // 1b. shared declarative blocks (tls/transport/multiplex/dial/quic)
  for (let name in [ "tls", "transport", "multiplex", "dial", "quic" ]) {
    let m = require(sprintf("builder._shared.%s", name));
    let es = m.emit_spec || {};
    walk_seq(es.seq); walk_seq(es.outbound); walk_seq(es.inbound);
  }
  // 1c. flat *_action shared blocks (export fields())
  for (let name in [ "route_action", "dns_action" ]) {
    let m = require(sprintf("builder._shared.%s", name));
    for (let f in m.fields()) note(f.json_key);
  }

  // ---- 2. collect every key present in any golden (recursive) ----
  let present = {};       // leaf key -> 1
  let golden_names = {};   // base filename (no .json) -> 1
  function collect(x) {
    let ty = type(x);
    if (ty === "object") { for (let k in keys(x)) { present[k] = 1; collect(x[k]); } }
    else if (ty === "array") { for (let e in x) collect(e); }
  }
  let files = fs.glob("tests/parity/golden/*.json") || [];
  for (let path in files) {
    let m = match(path, /\/([^\/]+)\.json$/);
    if (m) golden_names[m[1]] = 1;
    let f = fs.open(path, "r"); if (f == null) continue;
    let txt = f.read("all"); f.close();
    let j; try { j = json(txt); } catch (e) { continue; }
    collect(canon(j));
  }

  // ---- 3. allowlist ----
  let allow = {};
  let af = fs.open("tests/parity/coverage_allowlist.txt", "r");
  if (af != null) {
    let line; while ((line = af.read("line")) != null) {
      line = trim(line);
      if (!length(line) || substr(line, 0, 1) === "#") continue;
      // strip inline comment
      let h = index(line, "#"); if (h >= 0) line = trim(substr(line, 0, h));
      allow[leaf(line)] = 1;
    }
    af.close();
  }

  // ---- 4. report uncovered ----
  let missing = [];
  for (let k in keys(declared))
    if (!present[k] && !allow[k]) push(missing, k);
  // emit-only descriptors: require a golden whose name starts with the type
  for (let kt in keys(emit_only)) {
    let tp = split(kt, ":")[1];
    let found = false;
    for (let g in keys(golden_names)) if (index(g, tp) === 0) found = true;
    if (!found && !allow[kt]) push(missing, sprintf("emit-only:%s", kt));
  }
  if (length(missing)) {
    for (let k in sort(missing)) print(sprintf("UNCOVERED %s\n", k));
    print(sprintf("FAILS=%d\n", length(missing)));
  } else {
    print("ALLOK\n");
  }
')
echo "$out"
echo "$out" | grep -q "^ALLOK$" || { echo "FAIL: parity coverage gaps (add a corpus fixture + golden, or allowlist with a reason)"; exit 1; }
echo "test_parity_coverage_guard: all PASS"
