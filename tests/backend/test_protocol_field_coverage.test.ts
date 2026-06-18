import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_field_coverage.sh
// COVERAGE GUARD: every registered outbound descriptor's field set must be
// documented in docs/protocol-coverage.md.
//
// Strategy (Option A from spec):
//   1. Check the protocol-specific section (## <proto> outbound) first.
//   2. Fall back to the "## Shared TLS block" section for TLS-family fields.
// This mirrors what the shell test does with awk/grep.

const COVERAGE_DOC = "docs/protocol-coverage.md";

// Build the full set of field names documented in the Shared TLS block.
function getSharedTlsFields(doc: string): Set<string> {
  const lines = doc.split("\n");
  const sharedFields = new Set<string>();
  let inShared = false;
  for (const line of lines) {
    if (/^##\s+Shared TLS block/.test(line)) {
      inShared = true;
      continue;
    }
    if (inShared && /^##\s/.test(line)) {
      // End of shared section
      break;
    }
    if (inShared) {
      // Extract UCI field names from table rows: `| ... | uci_field_name | ...`
      // The UCI column is the second column in the Shared TLS block table.
      const m = line.match(/^\|[^|]+\|\s*`([^`]+)`/);
      if (m) {
        sharedFields.add(m[1]);
      }
    }
  }
  return sharedFields;
}

// Extract lines between the "### <proto> outbound" heading and the next "### " heading.
function getProtoSection(doc: string, proto: string): string {
  const lines = doc.split("\n");
  const heading = new RegExp(`^###\\s+${proto}\\s+outbound`);
  let found = false;
  const section: string[] = [];
  for (const line of lines) {
    if (!found) {
      if (heading.test(line)) {
        found = true;
      }
      continue;
    }
    if (/^###\s/.test(line)) break;
    section.push(line);
  }
  return section.join("\n");
}

describe("protocol field coverage guard", () => {
  useGuest();

  it("every registered outbound field is documented in protocol-coverage.md", async () => {
    // Host-side: read the coverage doc
    let doc: string;
    try {
      doc = readFileSync(COVERAGE_DOC, "utf8");
    } catch {
      throw new Error(`Cannot read ${COVERAGE_DOC} — is CWD the repo root?`);
    }

    const sharedTlsFields = getSharedTlsFields(doc);

    // Guest-side: enumerate all registered outbound descriptor fields
    // require("outbound") triggers all eager-loads, registering every descriptor.
    // We enumerate types_for_kind("outbound") and emit "<proto>\t<field1>,<field2>,..." lines.
    const src = `
      let ob = require("outbound");
      let reg = require("builder.protocols.registry");
      let types = reg.types_for_kind("outbound");
      for (let proto in types) {
        let d = reg.get("outbound", proto);
        if (d == null) continue;
        // Collect field names from descriptor fields[]
        let names = [];
        if (type(d.fields) === "array") {
          for (let f in d.fields) {
            if (f.name) push(names, f.name);
          }
        }
        // Also collect from groups[].fields[] recursively
        function collect_group_fields(groups) {
          if (type(groups) !== "array") return;
          for (let g in groups) {
            if (type(g.fields) === "array") {
              for (let f in g.fields) { if (f.name) push(names, f.name); }
            }
            collect_group_fields(g.groups);
          }
        }
        collect_group_fields(d.groups);
        printf("%s\\t%s\\n", proto, join(",", names));
      }
    `;

    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);

    // Parse the output and check coverage
    const failures: string[] = [];
    const lines = r.stdout.split("\n").filter((l) => l.includes("\t"));

    for (const line of lines) {
      const [proto, fieldsCsv] = line.split("\t", 2);
      if (!proto || !fieldsCsv) continue;
      const fields = fieldsCsv.split(",").filter((f) => f.length > 0);
      const protoSection = getProtoSection(doc, proto);

      for (const field of fields) {
        // Skip meta-fields that are internal UCI/ucode markers
        if (field.startsWith(".") || field === "enabled" || field === "type") {
          continue;
        }
        // Check in protocol-specific section first, then Shared TLS block
        const inProtoSection = protoSection.includes(field);
        const inSharedTls = sharedTlsFields.has(field);
        if (!inProtoSection && !inSharedTls) {
          failures.push(`${proto}.${field} not found in coverage doc`);
        }
      }
    }

    expect(failures).toEqual([]);
  });
});
