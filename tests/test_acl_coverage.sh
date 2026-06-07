#!/bin/sh
# tests/test_acl_coverage.sh
# Verifies that every method in read.ubus is on a safe-for-read whitelist
# and write.ubus is on an expected whitelist. Catches drift where a
# write-side method is accidentally added to read.ubus.
set -e
cd "$(dirname "$0")/.."

ACL_FILE="luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-app-singbox-ui.json"

if [ ! -f "$ACL_FILE" ]; then
    echo "FAIL: ACL file missing at $ACL_FILE"
    exit 1
fi

# Whitelist of methods safe for read.ubus.
# A method may be here ONLY if it satisfies ALL of:
#   - never writes to UCI
#   - never invokes nft (system mutation)
#   - never starts/stops/restarts singbox-ui service
#   - scrubs secrets on any returned config/section content (via lib/scrub.uc)
# If you add a new RPC method to read.ubus, also add it here and prove the
# above invariants hold in the handler.
SAFE_READ_METHODS="status status_detail read_config clash_get export_section preview_config protocol_schema"

# Whitelist of methods expected in write.ubus.
EXPECTED_WRITE_METHODS="generate nftables restart refresh clash_mutate reveal_token_grant reveal_token_revoke"

# Use jsonfilter (available on OpenWrt). On a generic host CI box it usually
# isn't present, so fall back to python3. If neither is available, SKIP
# rather than hard-fail — the Docker run will exercise jsonfilter properly.
extract_methods() {
    # $1 = "read" | "write"
    section="$1"
    if command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$ACL_FILE" -e "@[\"luci-app-singbox-ui\"].$section.ubus[\"singbox-ui\"][*]"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "
import json
d=json.load(open('$ACL_FILE'))
for m in d['luci-app-singbox-ui']['$section']['ubus']['singbox-ui']:
    print(m)
"
    else
        return 99
    fi
}

rc=0
read_methods=$(extract_methods read) || rc=$?
if [ "$rc" = 99 ]; then
    echo "SKIP: no jsonfilter or python3 on host; ACL coverage delegates to Docker"
    exit 0
fi
write_methods=$(extract_methods write)

fail=0

for m in $read_methods; do
    case " $SAFE_READ_METHODS " in
        *" $m "*) ;;
        *)
            echo "FAIL: method '$m' is in read.ubus but not on the safe-read whitelist"
            echo "      (every read.ubus method must be UCI-write-free, nft-free,"
            echo "      service-restart-free, and scrub its output)"
            fail=1
            ;;
    esac
done

for m in $write_methods; do
    case " $EXPECTED_WRITE_METHODS " in
        *" $m "*) ;;
        *)
            echo "FAIL: method '$m' is in write.ubus but not in expected whitelist"
            fail=1
            ;;
    esac
done

# Also verify that no method is in BOTH lists (the clash_request bug we just
# fixed): the same method name appearing in both ACL groups is a sign that
# read-vs-write semantics weren't carefully split.
for m in $read_methods; do
    case " $write_methods " in
        *" $m "*)
            echo "FAIL: method '$m' is in both read.ubus and write.ubus — split it"
            fail=1
            ;;
    esac
done

# Regression: legacy clash_request must not appear anywhere in the ACL.
if grep -q '"clash_request"' "$ACL_FILE"; then
    echo "FAIL: legacy 'clash_request' still present in ACL — must be removed"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "PASS: ACL coverage"
fi
exit $fail
