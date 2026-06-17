#!/bin/sh
# tests/test_version_gate_coverage.sh — schema-level coverage for the project-wide
# version-gate annotation sweep (Phase 4). Asserts representative min_version
# (post-1.12 additions) and max_version (deprecated-removed) tags survive the
# dump_all() projection — catches a regression that strips the version metadata.
set -eu
LIB="luci-singbox-ui/root/usr/share/singbox-ui/lib"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
require("outbound");   // eager-loads protocol descriptors (direct/hysteria/...)
let sd = require("builder.protocols.schema_dump");
let all = sd.dump_all();

function field(kind, type, name) {
    let m = all[kind][type]; if (m == null) return null;
    for (let f in (m.fields || [])) if (f.name == name) return f;
    return null;
}
function expect(label, got, want) {
    if (got != want) { print(sprintf("FAIL: %s = '%s' (want '%s')\n", label, got ?? "<null>", want)); exit(1); }
}

// --- per-field min_version (1.13/1.14 additions) ---
let mr = field("dns_rule", "default", "match_response");
if (mr == null) { print("FAIL: dns_rule.default.match_response missing\n"); exit(1); }
expect("dns_rule.default.match_response.min_version", mr.min_version, "1.14");

let iface = field("dns_rule", "default", "interface_address");
if (iface == null) { print("FAIL: interface_address missing\n"); exit(1); }
expect("dns_rule.default.interface_address.min_version", iface.min_version, "1.13");

let asd = field("dns", "tailscale", "accept_search_domain");
if (asd == null) { print("FAIL: tailscale.accept_search_domain missing\n"); exit(1); }
expect("dns.tailscale.accept_search_domain.min_version", asd.min_version, "1.14");

// --- per-field max_version (deprecated-removed) ---
let strat = field("dns_rule", "default", "strategy");
if (strat == null) { print("FAIL: dns_rule.default.strategy missing\n"); exit(1); }
expect("dns_rule.default.strategy.max_version", strat.max_version, "1.16");

let ova = field("outbound", "direct", "override_address");
if (ova == null) { print("FAIL: outbound.direct.override_address missing\n"); exit(1); }
expect("outbound.direct.override_address.max_version", ova.max_version, "1.13");

// inbound direct override_address must NOT be gated (deprecation is outbound-only).
let ina = field("inbound", "direct", "override_address");
if (ina != null && ina.max_version != null && ina.max_version != "") {
    print(sprintf("FAIL: inbound.direct.override_address wrongly gated max=%s\n", ina.max_version)); exit(1);
}

// --- type-level gates ---
expect("dns.mdns(type).min_version", all.dns.mdns.min_version, "1.14");
expect("dns.legacy(type).max_version", all.dns.legacy.max_version, "1.14");

print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q "OK" || { echo "FAIL: $out"; exit 1; }
echo "PASS: test_version_gate_coverage"
