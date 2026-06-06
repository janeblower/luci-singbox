#!/bin/sh
# tests/test_uci_schema_coverage.sh
# Verifies docs/uci-schema.md structure. Field-level coverage enforcement is
# added in Task 23.
set -e
SCHEMA="docs/uci-schema.md"

if [ ! -f "$SCHEMA" ]; then
  echo "FAIL: $SCHEMA missing"
  exit 1
fi

for anchor in inbound outbound ruleset route_rule route_default dns dns_server dns_rule cache log clash_api subscription; do
  if ! grep -q "^## \`$anchor\`" "$SCHEMA"; then
    echo "FAIL: schema missing section ## \`$anchor\`"
    exit 1
  fi
done

echo "PASS: schema structure"
