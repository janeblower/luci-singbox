#!/bin/sh
# tests/test_capability_drop.sh
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"
cd "$(dirname "$0")/../.."

# Capability file exists with correct shape
F=${SB_BACKEND_ROOT}/etc/capabilities/singbox-ui.json
[ -f "$F" ] || { echo "FAIL: $F missing"; exit 1; }
for cap in CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE; do
	grep -q "$cap" "$F" || { echo "FAIL: $cap missing from $F"; exit 1; }
done
echo "PASS: capability file lists 3 required caps"

# init.d declares capabilities param
grep -q 'procd_set_param capabilities' "${SB_BACKEND_ROOT}"/etc/init.d/singbox-ui \
	|| { echo "FAIL: init.d missing procd_set_param capabilities"; exit 1; }
echo "PASS: init.d wires capability file"

# Manifest installs it (backend package)
grep -q 'root/etc/capabilities/singbox-ui.json' scripts/install-manifest-singbox-ui.txt \
	|| { echo "FAIL: capability file not in install-manifest-singbox-ui.txt"; exit 1; }
echo "PASS: capability file in manifest"
