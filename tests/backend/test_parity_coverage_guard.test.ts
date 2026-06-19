import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_parity_coverage_guard.sh
// COVERAGE GUARD: every declared json_key (descriptor fields + groups +
// shared-block emit_spec + *_action fields, INCLUDING version-gated min/max
// fields read straight from the raw registry) and every emit-only descriptor
// type must have golden coverage under tests/parity/golden/.
// Minus the documented coverage_allowlist.txt.
//
// NOTE: protocol descriptors (outbound/inbound) are NOT loaded by dump_all()
// — they are eager-required below, mirroring outbound.uc / inbound.uc, so
// their fields and emit-only types are actually enumerated (this was the
// blind spot).
//
// This test reads host files (allowlist, golden dir) AND runs ucode enumeration
// in the guest. Full invariant is preserved.

describe("parity coverage guard", () => {
  useGuest();

  it("every declared json_key and emit-only type has golden or allowlist coverage", async () => {
    // The full ucode script: runs in guest with -L tests/parity (for corpus)
    // plus -L <lib>. This mirrors the shell's:
    //   "$UCODE_BIN" -L tests/parity -L "$LIB" -e '...'
    const src = `
  let fs    = require("fs");
  let canon = require("canon").canon;
  let reg   = require("builder.protocols.registry");
  require("builder.protocols.schema_dump").dump_all();  // eager-loads dns/route/dns_rule/settings registries
  // dump_all() does NOT load the protocol descriptors (outbound/inbound) —
  // those are eager-required by outbound.uc / inbound.uc on the production
  // path, not by schema_dump. Without this the guard enumerated ZERO protocol
  // json_keys and ZERO emit-only protocol types, so every protocol field
  // (including version-gated ones like hysteria.disable_mtu_discovery) and the
  // json/sharelink emit-only types were silently exempt from coverage. Mirror
  // both production require chains so types_for_kind("outbound"/"inbound") is
  // fully populated before enumeration.
  for (let _m in [
      "builder.protocols.direct", "builder.protocols.shadowsocks", "builder.protocols.vless",
      "builder.protocols.trojan", "builder.protocols.hysteria2", "builder.protocols.hysteria",
      "builder.protocols.tuic", "builder.protocols.anytls", "builder.protocols.shadowtls",
      "builder.protocols.json_raw", "builder.protocols.socks", "builder.protocols.http",
      "builder.protocols.vmess", "builder.protocols.ssh", "builder.protocols.naive",
      "builder.protocols.groups", "builder.protocols.tproxy", "builder.protocols.redirect",
      "builder.protocols.mixed", "builder.protocols.cloudflared" ])
    require(_m);

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
    let m = match(path, /\\/([^\\/]+)\\.json$/);
    if (m) golden_names[m[1]] = 1;
    let f = fs.open(path, "r"); if (f == null) continue;
    let txt = f.read("all"); f.close();
    let j; try { j = json(txt); } catch (e) { continue; }
    collect(canon(j));
  }

  // 2b. corpus fixtures keyed by exact "<kind>:<type>" whose golden exists.
  // emit-only descriptors expose no declarative json_key, so the guard binds
  // each to a parity fixture that the protocol-parity test actually BUILDS for
  // that exact kind+type and deep-equals against a golden. This is stricter
  // than a golden-filename prefix match (which would let an outbound:json
  // golden satisfy inbound:json) — the kind+type must line up.
  let corpus_kt = {};     // "<kind>:<type>" -> 1 (fixture present AND golden on disk)
  let corpus = require("corpus");
  for (let fx in (corpus || []))
    if (golden_names[fx.name])
      corpus_kt[sprintf("%s:%s", fx.kind, fx.type)] = 1;

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
  // emit-only descriptors: require a corpus fixture of the SAME kind+type whose
  // golden exists on disk (so the parity test exercises it). allowlistable by
  // the "<kind>:<type>" key if a fixture is structurally impossible.
  for (let kt in keys(emit_only))
    if (!corpus_kt[kt] && !allow[kt]) push(missing, sprintf("emit-only:%s", kt));
  if (length(missing)) {
    for (let k in sort(missing)) print(sprintf("UNCOVERED %s\\n", k));
    print(sprintf("FAILS=%d\\n", length(missing)));
  } else {
    print("ALLOK\\n");
  }
`;
    // Run with extra -L tests/parity so require("corpus") and require("canon") work
    const r = await runUcode(src, [], ["tests/parity"]);
    if (r.exitCode !== 0) {
      throw new Error(
        `ucode exit ${r.exitCode}\nstderr: ${r.stderr}\nstdout: ${r.stdout}`,
      );
    }
    expect(r.stdout).toContain("ALLOK");
    if (!r.stdout.includes("ALLOK")) {
      // Surface the uncovered items
      const uncovered = r.stdout
        .split("\n")
        .filter((l) => l.startsWith("UNCOVERED "))
        .join("\n");
      throw new Error(
        `Parity coverage gaps (add corpus fixture + golden, or allowlist with reason):\n${uncovered}`,
      );
    }
  });
});
