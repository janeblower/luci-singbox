import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_sharelink_coverage.sh
// COVERAGE GUARD: guards that the declarative share-link map can never silently
// drop a parameter:
//   (1) every INVENTORY param has a SPEC disposition and vice-versa (completeness)
//   (2) a maximal link per scheme lands at its declared sing-box path (behavioral)
// Also unit-tests the apply_params engine (set_path / coerce / gates).

describe("sharelink coverage", () => {
  useGuest();

  it("apply_params: set_path/csv/bool/int/gate/skip-handler", async () => {
    const src = `
let m = require("sharelink_map");
let o = {};
m.apply_params(
    { sni: "x.com", alpn: "h2,http/1.1", ins: "1", off: "0", n: "100 mbps" },
    [
        { param: "sni",   path: "tls.server_name", enables: "tls.utls.enabled" },
        { param: "alpn",  path: "tls.alpn",         transform: "csv" },
        { param: "ins",   path: "tls.insecure",     transform: "bool" },
        { param: "off",   path: "tls.never",        transform: "bool" },
        { param: "n",     path: "up_mbps",          transform: "int" },
        { param: "gated", path: "should.not",       when: { sni: "other" } },
        { param: "hand",  handler: "x" },
        { param: "uns",   unsupported: "because" },
    ], o);
print(sprintf("%s|%d|%s|%s|%s|%s|%s|%s",
    o.tls.server_name,
    length(o.tls.alpn),
    o.tls.insecure === true ? "T" : "?",
    o.tls.never == null ? "OMIT" : "LEAK",
    o.up_mbps,
    o.should == null ? "GATED" : "LEAK",
    o.hand == null ? "OK" : "LEAK",
    o.tls.utls.enabled === true ? "E" : "?"));
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("x.com|2|T|OMIT|100|GATED|OK|E");
  });

  it("completeness: every INVENTORY param has a SPEC disposition (and vice-versa)", async () => {
    const src = `
let m = require("sharelink_map");
let problems = [];
for (let scheme in m.INVENTORY) {
    let inv = {};
    for (let p in m.INVENTORY[scheme]) inv[p] = true;
    let spc = {};
    for (let e in (m.SPEC[scheme] ?? [])) spc[e.param] = true;
    for (let p in inv) if (!spc[p]) push(problems, sprintf("%s: INVENTORY param %s has no SPEC disposition", scheme, p));
    for (let p in spc) if (!inv[p]) push(problems, sprintf("%s: SPEC param %s not in INVENTORY", scheme, p));
}
print(length(problems) ? join("\\n", problems) : "CLEAN");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("CLEAN");
  });

  it("behavioral vless: reality short_id/public_key/fingerprint/flow land at declared paths", async () => {
    const url =
      "vless://11111111-1111-1111-1111-111111111111@h.ex:443?security=reality&sni=s.com&pbk=PK&sid=ab&flow=xtls-rprx-vision&fp=chrome#n";
    const expr = `sprintf('%s|%s|%s|%s', r.flow, r.tls.reality.short_id, r.tls.reality.public_key, r.tls.utls.fingerprint)`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("xtls-rprx-vision|ab|PK|chrome");
  });

  it("behavioral trojan: sni/transport type/service_name land at declared paths", async () => {
    const url =
      "trojan://pw@h.ex:443?sni=s.com&alpn=h2&type=grpc&serviceName=gs#n";
    const expr = `sprintf('%s|%s|%s', r.tls.server_name, r.transport.type, r.transport.service_name)`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|grpc|gs");
  });

  it("behavioral hysteria2: sni/insecure/alpn land at declared paths", async () => {
    const url = "hy2://pw@h.ex:443?sni=s.com&insecure=1&alpn=h3#n";
    const expr = `sprintf('%s|%s|%d', r.tls.server_name, r.tls.insecure===true?'T':'?', length(r.tls.alpn))`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|T|1");
  });

  it("behavioral tuic: uuid/congestion_control/sni land at declared paths", async () => {
    const url =
      "tuic://11111111-1111-1111-1111-111111111111:pw@h.ex:443?congestion_control=bbr&sni=s.com#n";
    const expr = `sprintf('%s|%s|%s', r.uuid, r.congestion_control, r.tls.server_name)`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      "11111111-1111-1111-1111-111111111111|bbr|s.com",
    );
  });

  it("behavioral hysteria1: auth_str/peer/up_mbps land at declared paths", async () => {
    const url = "hysteria://h.ex:443?auth=tok&peer=s.com&upmbps=50#n";
    const expr = `sprintf('%s|%s|%d', r.auth_str, r.tls.server_name, r.up_mbps)`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("tok|s.com|50");
  });

  it("behavioral anytls: sni/alpn land at declared paths", async () => {
    const url = "anytls://pw@h.ex:443?sni=s.com&alpn=h2#n";
    const expr = `sprintf('%s|%d', r.tls.server_name, length(r.tls.alpn))`;
    const src = `let r = require("sharelink").parse_proxy_url("${url}"); print(${expr});`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("s.com|1");
  });
});
