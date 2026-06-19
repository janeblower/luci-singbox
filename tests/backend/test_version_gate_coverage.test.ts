import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_version_gate_coverage.sh
// Schema-level coverage: representative min_version and max_version tags must
// survive dump_all() projection (catches a regression that strips version metadata).

describe("version gate coverage", () => {
  useGuest();

  it("per-field min/max version gates survive dump_all projection", async () => {
    const src = `
require("outbound");
let sd = require("builder.protocols.schema_dump");
let all = sd.dump_all();

function field(kind, type_, name) {
    let m = all[kind][type_]; if (m == null) return null;
    for (let f in (m.fields || [])) if (f.name == name) return f;
    return null;
}
function expect(label, got, want) {
    if (got != want) { print(sprintf("FAIL: %s = '%s' (want '%s')\\n", label, got ?? "<null>", want)); exit(1); }
}

// --- per-field min_version (1.13/1.14 additions) ---
let mr = field("dns_rule", "default", "match_response");
if (mr == null) { print("FAIL: dns_rule.default.match_response missing\\n"); exit(1); }
expect("dns_rule.default.match_response.min_version", mr.min_version, "1.14");

let iface = field("dns_rule", "default", "interface_address");
if (iface == null) { print("FAIL: interface_address missing\\n"); exit(1); }
expect("dns_rule.default.interface_address.min_version", iface.min_version, "1.13");

let asd = field("dns", "tailscale", "accept_search_domain");
if (asd == null) { print("FAIL: tailscale.accept_search_domain missing\\n"); exit(1); }
expect("dns.tailscale.accept_search_domain.min_version", asd.min_version, "1.14");

// --- per-field max_version (deprecated-removed) ---
let strat = field("dns_rule", "default", "strategy");
if (strat == null) { print("FAIL: dns_rule.default.strategy missing\\n"); exit(1); }
expect("dns_rule.default.strategy.max_version", strat.max_version, "1.16");

let ova = field("outbound", "direct", "override_address");
if (ova == null) { print("FAIL: outbound.direct.override_address missing\\n"); exit(1); }
expect("outbound.direct.override_address.max_version", ova.max_version, "1.13");

// inbound direct override_address must NOT be gated (deprecation is outbound-only).
let ina = field("inbound", "direct", "override_address");
if (ina != null && ina.max_version != null && ina.max_version != "") {
    print(sprintf("FAIL: inbound.direct.override_address wrongly gated max=%s\\n", ina.max_version)); exit(1);
}

// --- type-level gates ---
expect("dns.mdns(type).min_version", all.dns.mdns.min_version, "1.14");
expect("dns.legacy(type).max_version", all.dns.legacy.max_version, "1.14");

print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
