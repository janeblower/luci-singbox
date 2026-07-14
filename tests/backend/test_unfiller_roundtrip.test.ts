import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { buildParity } from "../helpers/parity.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

// COVERAGE GUARD for the JSON editor's reverse mapping.
//
// builder/_unfiller.uc must be an exact inverse of builder/_filler.uc. The
// strongest proof available is the parity corpus, which exists precisely because
// it covers every emit feature combination: nested groups, gates, tagged-union
// transports, users lists, single_fallback credentials, merge blocks, every
// coerce variant, version-gated fields.
//
// For every fixture:
//   json1 = filler.build(d, section)
//   r     = unfiller.parse(d, json1)
//   json2 = filler.build(d, <section rebuilt from r>)
//   json1 == json2   (semantically — key order is not load-bearing here)
//
// The rebuilt section carries ONLY what lib/json_editor.js writes back: the
// section name, the discriminator, r.fields, and r.extra stashed in json_extra.
// So a field _unfiller fails to map cannot quietly vanish — it either breaks the
// round-trip or surfaces in `extra`, which the UI makes the user confirm.

// Key order is not load-bearing (the project's parity invariant is semantic), and
// json_extra merges last, so canonicalise before comparing.
// The parity corpus is inbound/outbound only, but the JSON editor works on six
// kinds. These cover the other four — every one of them exercising the shapes the
// inverse could get wrong: a derived key (rule-set `format`, sniffed from the
// url/path extension and not a UCI option at all), a duration coerce
// ("86400s" <-> "86400"), a headerless descriptor (route_rule/dns_rule carry
// neither type nor tag), list matchers, and the tls shared block resolved through
// the OUTBOUND sequence (a DNS server is a TLS client).
const EXTRA_FIXTURES = `[
  { name: "rs_remote_srs", kind: "rule_set", type: "remote",
    section: { ".name": "geosite", type: "remote",
               url: "https://example.com/geosite.srs", update_interval: "86400",
               download_detour: "proxy", nft_rules: "1" } },
  { name: "rs_remote_json_no_interval", kind: "rule_set", type: "remote",
    section: { ".name": "gs2", type: "remote", url: "https://example.com/g.json" } },
  { name: "rs_local", kind: "rule_set", type: "local",
    section: { ".name": "cn", type: "local", path: "/etc/rules/cn.srs" } },
  { name: "dns_https_tls", kind: "dns", type: "https",
    section: { ".name": "goog", type: "https", server: "8.8.8.8", server_port: "443",
               path: "/dns-query", detour: "proxy",
               tls_enabled: "1", tls_server_name: "dns.google", tls_alpn: [ "h2" ] } },
  { name: "dns_fakeip", kind: "dns", type: "fakeip",
    section: { ".name": "fk", type: "fakeip", inet4_range: "198.18.0.0/15",
               inet6_range: "fc00::/18" } },
  { name: "route_rule_default", kind: "route_rule", type: "default",
    section: { ".name": "r1", type: "default", action: "route", outbound: "proxy",
               domain_suffix: [ "example.com", ".ru" ], port: [ "443" ],
               invert: "1" } },
  { name: "route_rule_reject", kind: "route_rule", type: "default",
    section: { ".name": "r2", type: "default", action: "reject", method: "drop",
               no_drop: "1", ip_cidr: [ "10.0.0.0/8" ] } },
  { name: "dns_rule_default", kind: "dns_rule", type: "default",
    section: { ".name": "dr1", type: "default", action: "route", server: "goog",
               domain_suffix: [ ".ru" ] } }
]`;

const DRIVER = `
  let filler   = require("builder._filler");
  let unfiller = require("builder._unfiller");
  require("inbound");
  require("outbound");
  require("builder.dns.registry");
  require("builder.dns_rule.registry");
  require("builder.route.registry");
  let reg    = require("builder.protocols.registry");
  let corpus = [ ...require("corpus"), ...${EXTRA_FIXTURES} ];

  function canon(v) {
    if (type(v) === "array")  { let a = []; for (let x in v) push(a, canon(x)); return a; }
    if (type(v) === "object") { let o = {}; for (let k in sort(keys(v))) o[k] = canon(v[k]); return o; }
    return v;
  }

  // The UCI discriminator is "protocol" for inbounds and "type" for everything
  // else; a headerless kind (route_rule / dns_rule) has no tag in its JSON.
  function discr(kind) { return kind === "inbound" ? "protocol" : "type"; }

  let out = [];
  for (let fx in corpus) {
    let d = reg.get(fx.kind, fx.type);
    if (d == null) { push(out, { name: fx.name, skipped: "no descriptor" }); continue; }

    let j1 = filler.build(d, fx.section);
    if (j1 == null) { push(out, { name: fx.name, skipped: "build returned null" }); continue; }

    let r = unfiller.parse(d, j1);

    // Exactly what the JSON editor writes back — nothing else.
    let s2 = { ".name": fx.section[".name"] };
    s2[discr(fx.kind)] = fx.type;
    for (let k in r.fields) s2[k] = r.fields[k];
    if (length(keys(r.extra))) s2.json_extra = sprintf("%J", r.extra);

    let j2 = filler.build(d, s2);

    push(out, {
      name:  fx.name,
      kind:  fx.kind,
      type:  fx.type,
      same:  sprintf("%J", canon(j1)) == sprintf("%J", canon(j2)),
      extra: keys(r.extra),
      j1:    sprintf("%J", j1),
      j2:    sprintf("%J", j2),
    });
  }
  print(sprintf("%J", out));
`;

interface Row {
  name: string;
  kind?: string;
  type?: string;
  same?: boolean;
  extra?: string[];
  j1?: string;
  j2?: string;
  skipped?: string;
}

// Fixtures that legitimately never reach the filler, so there is nothing to
// invert. Hardcoded so a NEW one can't slip in unnoticed:
//   awg_warp_basic — a plugin descriptor; its lib dir is not on this -L path
//
// cloudflared_in and json_in_raw used to land here too, but only because
// filler.build() unconditionally required listen_port for ANY kind:"inbound"
// descriptor (this DRIVER calls filler.build() directly, bypassing their
// emit() escape hatch on purpose, to exercise the declarative path). Now that
// build() only requires listen_port for descriptors declaring shared:
// {listen:true} (added for tun, which is not a listener), both build a bare
// {type,tag} header instead of returning null, and round-trip trivially
// (neither has anything to invert: json_in_raw's raw_json field has no
// json_key, and cloudflared's own fields are exercised only via its emit()).
const EXPECTED_SKIPS = ["awg_warp_basic"];

describe("_unfiller round-trips the whole parity corpus", () => {
  useGuest();

  let rows: Row[] = [];

  it("runs every fixture through build -> parse -> build", async () => {
    // Same pin as the parity lane (buildParity: SINGBOX_CORE_VERSION=99.0). The
    // corpus carries version-gated fields (kTLS 1.13, QUIC 1.14); on the guest's
    // real 1.12 core _filler would gate them out of j1 entirely and this guard
    // would quietly stop round-tripping them. Pinned high, every field is present
    // on both sides. The gated direction — a key _filler won't emit must land in
    // `extra` and be re-emitted verbatim, never be silently dropped from `known` —
    // is pinned per-case in test_shared_version_gate.test.ts.
    rows = (await buildParity(DRIVER, ["tests/parity"])) as Row[];
    // 76 protocol fixtures + the 8 covering the other four kinds.
    expect(rows.length).toBeGreaterThan(80);
    expect(
      rows
        .filter((r) => r.skipped)
        .map((r) => r.name)
        .sort(),
    ).toEqual(EXPECTED_SKIPS);
  });

  it("is an exact inverse for every fixture", () => {
    const drifted = rows
      .filter((r) => !r.skipped && !r.same)
      .map(
        (r) => `${r.kind}/${r.type} ${r.name}\n  was: ${r.j1}\n  got: ${r.j2}`,
      );
    expect(drifted).toEqual([]);
  });

  it("leaves nothing unmapped except a discard-column users list", () => {
    // Anything else here means _unfiller grew a blind spot: a key the descriptor
    // DOES model but the inverse walk missed. It would still survive (json_extra
    // re-emits it verbatim), but the user would be asked to confirm a field the
    // form already owns — and worse, the form and the raw copy could then drift.
    //
    // shadowsocks is the sole exception: its users spec `discard`s the `method`
    // column, so the emitted JSON carries nothing to rebuild the UCI row from.
    const unexpected = rows
      .filter((r) => !r.skipped && (r.extra?.length ?? 0) > 0)
      .filter((r) => !(r.extra?.length === 1 && r.extra[0] === "users"))
      .map((r) => `${r.name}: ${r.extra?.join(", ")}`);
    expect(unexpected).toEqual([]);

    const withUsers = rows.filter((r) => r.extra?.includes("users"));
    expect(withUsers.length).toBeGreaterThan(0);
    for (const r of withUsers) expect(r.type).toBe("shadowsocks");
  });

  it("covers all six kinds the JSON editor works on", () => {
    // The parity corpus is inbound/outbound only. If the editor grows a kind
    // whose inverse nothing exercises, that is exactly the blind spot this guard
    // exists to prevent.
    const kinds = new Set(rows.filter((r) => !r.skipped).map((r) => r.kind));
    expect([...kinds].sort()).toEqual([
      "dns",
      "dns_rule",
      "inbound",
      "outbound",
      "route_rule",
      "rule_set",
    ]);
  });

  it("round-trips a rule-set's derived format and its duration interval", () => {
    // `format` is sniffed from the source's extension and is not a UCI option at
    // all; `update_interval` is stored as plain seconds and emitted as "86400s".
    // Both used to be bolted on AFTER the filler in ruleset.uc, which meant the
    // editor exported an object the real config did not match and could not invert
    // those two keys — they would have round-tripped into json_extra and then been
    // emitted twice.
    const srs = rows.find((r) => r.name === "rs_remote_srs");
    expect(srs?.same).toBe(true);
    expect(srs?.extra).toEqual([]);
    expect(srs?.j1).toContain('"format": "binary"');
    expect(srs?.j1).toContain('"update_interval": "86400s"');

    // .json source -> format "source", and no interval means no key at all.
    const js = rows.find((r) => r.name === "rs_remote_json_no_interval");
    expect(js?.same).toBe(true);
    expect(js?.j1).toContain('"format": "source"');
    expect(js?.j1).not.toContain("update_interval");
  });

  it("tun: a pasted listen_port does not become a UCI field (F3 regression)", async () => {
    // tun is kind:"inbound" but declares no shared:{listen:true} — sing-box
    // rejects listen_port on it outright. _unfiller.parse() used to hardcode
    // `if (d.kind === "inbound")` to claim listen/listen_port, same bug
    // _filler.build() had before cde028ae's shared.listen gate. A tun JSON
    // carrying a copy-pasted listen_port (from another inbound, or the doc
    // page's bogus "Listen Fields" section) must NOT turn into a dead
    // `option listen_port` — it has to surface as an unmapped/extra key instead,
    // so the JSON editor asks the user about it rather than silently writing it.
    const src = `
      let unfiller = require("builder._unfiller");
      require("inbound");
      let reg = require("builder.protocols.registry");
      let d = reg.get("inbound", "tun");
      let r = unfiller.parse(d, {
        type: "tun", tag: "t1", address: [ "172.19.0.1/30" ],
        listen_port: 1080, auto_route: true,
      });
      print(sprintf("%J\\n", r));
    `;
    const r = await runUcodeJSON<{
      fields: Record<string, unknown>;
      extra: Record<string, unknown>;
      known: Record<string, unknown>;
    }>(src);

    expect(r.fields).toEqual({
      address: ["172.19.0.1/30"],
      auto_route: "1",
    });
    expect(r.fields.listen_port).toBeUndefined();
    expect(r.extra.listen_port).toBe(1080);
    expect(r.known.listen_port).toBeUndefined();
    expect(r.known.listen).toBeUndefined();
  });
});
