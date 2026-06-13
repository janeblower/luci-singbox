#!/bin/sh
# tests/test_dns_schema_rpc.sh
# Validates that schema_dump.dump_all() includes a 'dns' key with all 14 DNS
# types, each having a fields array and sing_box_type, and that backend-only
# props (json_key, coerce, omit_when, skip_value, requires, default_when_empty,
# only_values) do NOT leak through the FIELD_WHITELIST projection.
set -e
cd "$(dirname "$0")/.."

# Locate ucode the same way the other ucode tests do.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=$(command -v ucode)
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP test_dns_schema_rpc (ucode missing)"
	exit 0
fi

# shellcheck disable=SC2086
je() {
	# je EXPR — read JSON from stdin, eval ucode boolean EXPR (parsed object bound
	# as `d`); exit 0 if truthy, 1 otherwise.
	expr_="$1"
	"$UCODE_BIN" $UCODE_LIB_FLAGS -e "
		let fs = require(\"fs\");
		let raw = fs.stdin.read(\"all\") || \"\";
		let d;
		try { d = json(raw); } catch (_) { exit(1); }
		exit(d != null && ($expr_) ? 0 : 1);
	"
}

echo "-- dump_all() includes dns key with 14 types"

# 1. dump_all() returns an object with a 'dns' key
out="$("$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let dump = require("builder.protocols.schema_dump").dump_all();
	print(sprintf("%J", dump));
')"

printf '%s\n' "$out" | je 'type(d.dns) === "object"' \
	|| { echo "FAIL: dump_all() has no 'dns' key or dns is not an object"; exit 1; }
echo "PASS dump_all() has dns key"

# 2. Spot-check: expected DNS types present
dns_json="$(printf '%s\n' "$out" | "$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let fs = require("fs");
	let raw = fs.stdin.read("all") || "";
	let d = json(raw);
	print(sprintf("%J", d.dns));
')"

for expected_type in udp tls https fakeip legacy tcp quic h3 local hosts dhcp mdns tailscale resolved; do
	printf '%s\n' "$dns_json" | je "d[\"$expected_type\"] != null" \
		|| { echo "FAIL: dns type '$expected_type' missing from dump_all().dns"; exit 1; }
done
echo "PASS all 14 dns types present (udp, tls, https, fakeip, legacy, tcp, quic, h3, local, hosts, dhcp, mdns, tailscale, resolved)"

# 3. Each dns type has fields[] array and sing_box_type string
printf '%s\n' "$dns_json" | "$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let fs = require("fs");
	let raw = fs.stdin.read("all") || "";
	let dns = json(raw);
	let errs = [];
	for (let t in keys(dns)) {
		let entry = dns[t];
		if (type(entry.fields) !== "array")
			push(errs, t + ": missing fields[]");
		if (entry.sing_box_type == null)
			push(errs, t + ": missing sing_box_type");
	}
	if (length(errs)) {
		for (let e in errs) warn(e + "\n");
		exit(1);
	}
	exit(0);
' || { echo "FAIL: dns types missing fields[] or sing_box_type"; exit 1; }
echo "PASS all dns type entries have fields[] and sing_box_type"

# 4. No backend-only props leak through FIELD_WHITELIST projection.
# Walks every field in every dns type and fails if any backend-only key appears.
leak_check="$(printf '%s\n' "$dns_json" | "$UCODE_BIN" $UCODE_LIB_FLAGS -e '
	let fs = require("fs");
	let raw = fs.stdin.read("all") || "";
	let dns;
	try { dns = json(raw); } catch (_) { print("FAIL_PARSE\n"); exit(0); }
	if (dns == null) { print("FAIL_NULL\n"); exit(0); }
	let backend_props = ["json_key","coerce","omit_when","skip_value","requires","default_when_empty","only_values"];
	let leaks = [];
	for (let t in keys(dns)) {
		let entry = dns[t];
		if (type(entry.fields) !== "array") continue;
		for (let f in entry.fields) {
			for (let bp in backend_props) {
				if (f[bp] != null)
					push(leaks, "dns." + t + "." + (f.name || "?") + ":" + bp);
			}
		}
	}
	if (length(leaks)) {
		print("LEAK:" + join(",", leaks) + "\n");
	} else {
		print("CLEAN\n");
	}
')"
[ "$leak_check" = "CLEAN" ] || { echo "FAIL backend prop(s) leaked to dns schema: $leak_check"; exit 1; }
echo "PASS schema dump strips all backend-only props from dns projection"

echo "PASS test_dns_schema_rpc"
