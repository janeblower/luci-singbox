#!/bin/sh
# tests/backend/test_acl_coverage.sh
# Verifies every method in read.ubus is on a safe-for-read whitelist and
# write.ubus is on an expected whitelist — catches drift where a write-side
# method is accidentally added to read.ubus. One of the TWO ACL guards
# (the other is test_rpcd_acl_sync.sh): this one holds the SAFE_READ_METHODS
# hardcode invariant, so the whitelist MUST stay hand-maintained (not derived
# from the ACL). Moved from tests/cross/ to tests/backend/ (domain=directory:
# it tests the backend ACL contract) and rewritten to parse the ACL JSON in
# pure ucode — no jsonfilter/python3, so it runs on host AND in the VM where the
# ACL is actually deployed (the old jsonfilter/python3 fallback SKIPped both).
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

ACL_FILE="${SB_ACL}"
[ -f "$ACL_FILE" ] || { echo "FAIL: ACL file missing at $ACL_FILE"; exit 1; }

: "${UCODE_BIN:=$(command -v ucode)}"
[ -z "$UCODE_BIN" ] && { echo "SKIP: no ucode on host"; exit 0; }

# Whitelist of methods safe for read.ubus. A method may be here ONLY if it
# never writes UCI, never invokes nft, and never starts/stops/restarts the
# service. If you add a read.ubus method, add it here AND prove those invariants.
SAFE_READ_METHODS="status status_detail sub_status read_config clash_get clash_delay export_section preview_config protocol_schema"
EXPECTED_WRITE_METHODS="generate nftables restart refresh clash_mutate"

# Extract the read/write ubus method list from the ACL JSON in pure ucode.
# $1 = "read" | "write". Newline-separated method names on stdout.
extract_methods() {
    "$UCODE_BIN" -e '
        let fs = require("fs");
        let section = ARGV[0];
        let d = json(fs.readfile("'"$ACL_FILE"'") || "{}");
        let o = d["luci-singbox-ui"] ?? {};
        let arr = ((o[section] ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        for (let m in arr) print(m + "\n");
    ' -- "$1"
}

read_methods=$(extract_methods read)
write_methods=$(extract_methods write)
[ -n "$read_methods" ]  || { echo "FAIL: read.ubus empty or unparsable"; exit 1; }
[ -n "$write_methods" ] || { echo "FAIL: write.ubus empty or unparsable"; exit 1; }

fail=0

for m in $read_methods; do
    case " $SAFE_READ_METHODS " in
        *" $m "*) ;;
        *)
            echo "FAIL: method '$m' is in read.ubus but not on the safe-read whitelist"
            echo "      (every read.ubus method must be UCI-write-free, nft-free,"
            echo "      service-restart-free)"
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

# No method may be in BOTH lists (the clash_request bug class).
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

[ "$fail" -eq 0 ] && echo "PASS: ACL coverage"
exit $fail
