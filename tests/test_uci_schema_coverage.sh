#!/bin/sh
# tests/test_uci_schema_coverage.sh
# Verifies docs/uci-schema.md structure and field-level coverage.
# POSIX-portable: uses only sh, grep, sed, sort.
set -e
. "$(dirname "$0")/lib/sb_helpers.sh"
SCHEMA="docs/uci-schema.md"
LIB="${SB_LIB}"

if [ ! -f "$SCHEMA" ]; then
  echo "FAIL: $SCHEMA missing"
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 1: Section anchors (unchanged from pre-Task-23 check)
# ---------------------------------------------------------------------------
for anchor in inbound outbound ruleset route_rule route_default dns dns_server dns_rule cache log clash_api subscription; do
  if ! grep -q "^## \`$anchor\`" "$SCHEMA"; then
    echo "FAIL: schema missing section ## \`$anchor\`"
    exit 1
  fi
done

echo "PASS: schema structure"

# ---------------------------------------------------------------------------
# Step 2: Field-level enforcement
#
# Extract every UCI field name referenced in lib/*.uc via two strategies:
#   A) s_opt/s_num/s_bool("fieldname") — explicit accessor calls
#   B) section.fieldname direct access (conservative variable-name prefix set)
#
# Then assert each appears as a backtick-quoted name in the schema doc.
# ---------------------------------------------------------------------------

# Strategy A: s_opt / s_num / s_bool calls
fields_a=$(grep -hEo 's_(opt|num|bool)\([a-zA-Z_][a-zA-Z0-9_]*,[ 	]*"[a-z_][a-z0-9_]*"' \
    "$LIB"/*.uc \
  | sed -E 's/.*"([^"]+)".*/\1/' \
  | sort -u)

# Strategy B: direct section.fieldname access — only on known UCI-section
# variable names used in lib/*.uc (s, sec, section, cur, inb, ob, rs, rule,
# row, node, dns_s).  We intentionally use a narrow prefix set to avoid
# catching method chains (e.g. cursor.get_all, ob.uuid = ...).
fields_b=$(grep -hEo '\b(s|sec|section|cur|inb|ob|rs|rule|row|node|dns_s)\.[a-z_][a-z0-9_]+' \
    "$LIB"/*.uc \
  | sed -E 's/[^.]+\.//' \
  | sort -u)

# Combine and de-duplicate
all_fields=$(printf '%s\n%s\n' "$fields_a" "$fields_b" | sort -u)

# ---------------------------------------------------------------------------
# Whitelist: names that appear in the patterns above but are NOT UCI fields.
# These fall into four categories:
#   1. Internal JSON-emit keys (ob.uuid, ob.flow, ob.method, …)
#   2. Ucode built-in methods (foreach, get, get_all, …)
#   3. Intermediate local variables / object properties (mux, tls, …)
#   4. sing-box config-structure keys (not UCI storage)
# ---------------------------------------------------------------------------
is_whitelisted() {
  case "$1" in
    # JSON-emit keys (value comes from a real UCI field, not stored under this name)
    address|alter_id|flow|masquerade|method|multiplex|obfs|password|users|uuid) return 0 ;;
    # JSON-emit keys for tuic (value comes from real UCI fields: tuic_*)
    congestion_control|heartbeat|udp_over_stream|udp_relay_mode|zero_rtt_handshake) return 0 ;;
    # JSON-emit keys for anytls (value comes from real UCI fields: anytls_*)
    idle_session_check_interval|idle_session_timeout|min_idle_session) return 0 ;;
    # ucode built-ins / object methods
    foreach|get|get_all|push|length|split|join|keys|values|delete|format) return 0 ;;
    # local / intermediate variable properties (not UCI fields)
    tls|transport|handshake|rule_set|ruleset|outbound|network) return 0 ;;
    # ucode cursor / module locals
    cur|sq|uc|opts|tag|idx|name|size|raw|read|open|close|write|sh|txt|stat|lsdir|mkdir|unlink|popen) return 0 ;;
    # sing-box config structural fields (not UCI)
    inbounds|outbounds|dns|route|rules|servers|log|experimental|json) return 0 ;;
    # generated/computed local properties
    out_path|outpath|raw_path|v4|v6|timeout|user_agent) return 0 ;;
    # non-UCI transient/internal fields
    issued_ts|token) return 0 ;;
    # outbound module exported function (not a UCI field)
    parse_proxy_url|build_outbounds|build_constructor_for) return 0 ;;
    *) return 1 ;;
  esac
}

fail=0
missing_list=""

for field in $all_fields; do
  is_whitelisted "$field" && continue
  if ! grep -q "\`$field\`" "$SCHEMA"; then
    echo "FIELD MISSING IN SCHEMA: $field"
    missing_list="${missing_list} $field"
    fail=1
  fi
done

if [ "$fail" = "1" ]; then
  echo "FAIL: the following fields are referenced in lib/*.uc but not documented in $SCHEMA:"
  echo " $missing_list"
  exit 1
fi

echo "PASS: field-level schema coverage"

# ---------------------------------------------------------------------------
# C2.1.14: helpers.uc exports reset_iface_cache AND generate.uc invokes it.
# Each generate.uc run must wipe the module-scope iface→device cache so
# subscription reloads see fresh netdev mappings instead of stale entries
# left over from a prior generate within the same long-lived process.
# ---------------------------------------------------------------------------
HELPERS_UC="$LIB/helpers.uc"
GENERATE_UC="${SB_SHARE}/generate.uc"
grep -q 'reset_iface_cache' "$HELPERS_UC" \
	|| { echo "FAIL: C2.1.14: helpers.uc must export reset_iface_cache"; exit 1; }
grep -q 'reset_iface_cache' "$GENERATE_UC" \
	|| { echo "FAIL: C2.1.14: generate.uc must call helpers.reset_iface_cache()"; exit 1; }
echo "PASS: C2.1.14: reset_iface_cache wired"

# ---------------------------------------------------------------------------
# C2.1.15: shadowsocks ss_user format limitation (colon-truncated passwords)
# must be flagged both in production code (lib/inbound.uc) and in the schema
# (docs/uci-schema.md → inbound shadowsocks section) so operators are not
# silently bitten by ':'-in-password.
# ---------------------------------------------------------------------------
grep -qiE 'colon|truncat' "$LIB/inbound.uc" \
	|| { echo "FAIL: C2.1.15: ss_user colon-truncation comment missing from lib/inbound.uc"; exit 1; }
grep -qiE 'colon|truncat' "$SCHEMA" \
	|| { echo "FAIL: C2.1.15: ss_user colon-truncation note missing from $SCHEMA"; exit 1; }
echo "PASS: C2.1.15: ss_user limitation documented"
