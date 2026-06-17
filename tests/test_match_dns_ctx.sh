#!/bin/sh
set -eu
. "$(dirname "$0")/lib/sb_helpers.sh"
LIB="${SB_LIB}"
UCODE="${UCODE_BIN:-ucode}"
command -v "$UCODE" >/dev/null 2>&1 || { echo "SKIP: no ucode"; exit 0; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/t.uc" <<'UC'
let match = require("builder._shared.match");
function names(ctx) { let m = {}; for (let f in match.fields(ctx)) m[f.name] = f; return m; }
let dns  = names("dns");
let dnsh = names("dns_headless");
let route = names("route");
// DNS-only matchers present in dns:
for (let n in [ "query_type", "ip_accept_any", "match_response", "response_rcode",
                "response_answer", "interface_address", "preferred_by" ])
  if (!(n in dns)) { print(sprintf("FAIL: dns missing %s\n", n)); exit(1); }
// common matchers also in dns:
for (let n in [ "domain_suffix", "ip_cidr", "network", "protocol", "rule_set", "clash_mode" ])
  if (!(n in dns)) { print(sprintf("FAIL: dns missing common %s\n", n)); exit(1); }
// rule_set/inbound/auth_user/clash_mode/rule_set_ip_cidr_match_source NOT in dns_headless:
for (let n in [ "rule_set", "inbound", "auth_user", "clash_mode", "rule_set_ip_cidr_match_source" ])
  if (n in dnsh) { print(sprintf("FAIL: dns_headless has %s\n", n)); exit(1); }
// common matchers ARE in dns_headless:
if (!("domain_suffix" in dnsh)) { print("FAIL: dns_headless missing domain_suffix\n"); exit(1); }
// client is route-only, NOT in dns:
if ("client" in dns) { print("FAIL: dns has route-only client\n"); exit(1); }
if (!("client" in route)) { print("FAIL: route lost client\n"); exit(1); }
// version gates:
if (dns.match_response.min_version != "1.14") { print("FAIL: match_response min_version\n"); exit(1); }
if (dns.interface_address.min_version != "1.13") { print("FAIL: interface_address min_version\n"); exit(1); }
if (dns.rule_set_ip_cidr_accept_empty == null || dns.rule_set_ip_cidr_accept_empty.max_version != "1.16")
  { print("FAIL: accept_empty max_version\n"); exit(1); }
// route context unchanged for common matcher:
if (!("domain_suffix" in route)) { print("FAIL: route missing domain_suffix\n"); exit(1); }
print("OK\n");
UC
out="$("$UCODE" -L "$LIB" "$WORK/t.uc" 2>&1)"
echo "$out" | grep -q OK || { echo "FAIL: $out"; exit 1; }
echo "PASS"
