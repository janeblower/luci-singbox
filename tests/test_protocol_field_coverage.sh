#!/bin/sh
# tests/test_protocol_field_coverage.sh
# Asserts every registered outbound descriptor's field set is documented
# in docs/protocol-coverage.md. Catches "added UCI field, forgot to add
# to coverage matrix" drift.
#
# Search strategy (Option A from spec): check the protocol-specific section
# first, then fall back to the Shared TLS block. Common fields like
# server/server_port appear in every per-protocol section; TLS-family fields
# live in the shared block and are found via the fallback.

# shellcheck disable=SC2015
set -eu
cd "$(dirname "$0")/.."

UCODE_BIN="${UCODE_BIN:-ucode}"
UCODE_LIB_DIR="${UCODE_LIB_DIR:-luci-singbox-ui/root/usr/share/singbox-ui/lib}"

if ! command -v "$UCODE_BIN" >/dev/null 2>&1; then
	echo "SKIP test_protocol_field_coverage (ucode missing)"
	exit 0
fi

# Dump registered outbound fields per protocol via ucode.
# require("outbound") triggers all try{require("builder.protocols.*")} eager-loads,
# registering every descriptor. We then enumerate types_for_kind("outbound")
# and emit "<proto>\t<field1>,<field2>,..." lines.
# shellcheck disable=SC2086
dumped=$("$UCODE_BIN" -L "$UCODE_LIB_DIR" -e '
	require("outbound");
	let reg = require("builder.protocols.registry");
	for (let proto in reg.types_for_kind("outbound")) {
		let d = reg.get("outbound", proto);
		if (d == null || type(d.fields) !== "array") continue;
		let names = [];
		for (let f in d.fields) push(names, f.name);
		if (length(names) > 0)
			printf("%s\t%s\n", proto, join(",", names));
	}
') || { echo "FAIL ucode probe failed"; exit 1; }

if [ -z "$dumped" ]; then
	echo "FAIL no outbound descriptors registered"
	exit 1
fi

# Build shared section text once (awk extracts lines between "## Shared TLS block"
# and the next "## " heading).
shared_section=$(awk '
	/^## Shared TLS block/ { in_s=1; next }
	/^## /                 { in_s=0 }
	in_s                   { print }
' docs/protocol-coverage.md)

fail=0

# Process each "<proto>\t<fields-csv>" line.
# We write failures to a temp file to avoid the subshell variable-scope
# problem that some shells exhibit with "cmd | while read"; using a here-doc
# keeps everything in the current shell.
tmpfile=$(mktemp /tmp/pfcover.XXXXXX)
trap 'rm -f "$tmpfile"' EXIT

printf '%s\n' "$dumped" > "$tmpfile"

while IFS="	" read -r proto fields; do
	# Extract the per-protocol outbound section from the coverage doc.
	proto_section=$(awk -v p="$proto" '
		$0 ~ ("^### " p " outbound") { in_p=1; next }
		/^### /                       { in_p=0 }
		in_p                          { print }
	' docs/protocol-coverage.md)

	combined="$proto_section
$shared_section"

	# Iterate field names (comma-separated).
	old_ifs="$IFS"
	IFS=,
	for f in $fields; do
		IFS="$old_ifs"
		# Match the UCI name in backticks within the combined text.
		if printf '%s' "$combined" | grep -qF "\`$f\`"; then
			:
		else
			echo "FAIL [$proto] field '$f' not documented in docs/protocol-coverage.md"
			fail=1
		fi
		IFS=,
	done
	IFS="$old_ifs"
done < "$tmpfile"

if [ "$fail" -ne 0 ]; then
	exit 1
fi

echo "PASS test_protocol_field_coverage"
