import { describe, expect, it } from "bun:test";
import { existsSync, readFileSync } from "node:fs";

// Port of tests/backend/test_uci_schema_coverage.sh
// Verifies docs/uci-schema.md structure and field-level coverage.
// Steps 1+2: host-side grep against the schema doc.
// Steps C2.1.14 + C2.1.15: host-side grep against production source files.

const SCHEMA = "docs/uci-schema.md";

// Mirror the shell whitelist: names that appear in the extraction patterns
// but are NOT UCI fields (JSON-emit keys, ucode builtins, local variables,
// sing-box config structure keys).
const WHITELIST = new Set([
  // JSON-emit keys
  "address",
  "alter_id",
  "flow",
  "masquerade",
  "method",
  "multiplex",
  "obfs",
  "password",
  "users",
  "uuid",
  // tuic JSON-emit keys
  "congestion_control",
  "heartbeat",
  "udp_over_stream",
  "udp_relay_mode",
  "zero_rtt_handshake",
  // anytls JSON-emit keys
  "idle_session_check_interval",
  "idle_session_timeout",
  "min_idle_session",
  // ucode built-ins / object methods
  "foreach",
  "get",
  "get_all",
  "push",
  "length",
  "split",
  "join",
  "keys",
  "values",
  "delete",
  "format",
  // local / intermediate variable properties
  "tls",
  "transport",
  "handshake",
  "rule_set",
  "ruleset",
  "outbound",
  "network",
  // ucode cursor / module locals
  "cur",
  "sq",
  "uc",
  "opts",
  "tag",
  "idx",
  "name",
  "size",
  "raw",
  "read",
  "open",
  "close",
  "write",
  "sh",
  "txt",
  "stat",
  "lsdir",
  "mkdir",
  "unlink",
  "popen",
  // sing-box config structural fields
  "inbounds",
  "outbounds",
  "dns",
  "route",
  "rules",
  "servers",
  "log",
  "experimental",
  "json",
  // generated/computed local properties
  "out_path",
  "outpath",
  "raw_path",
  "v4",
  "v6",
  "timeout",
  "user_agent",
  // non-UCI transient/internal fields
  "issued_ts",
  "token",
  // outbound module exported functions
  "parse_proxy_url",
  "build_outbounds",
  "build_constructor_for",
]);

describe("uci schema coverage", () => {
  // Step 1 and C2.x are host-only; no guest needed for those.
  // Step 2 (field extraction from lib/*.uc) runs on host via readFileSync.

  it("schema file exists", () => {
    expect(existsSync(SCHEMA)).toBe(true);
  });

  it("schema has all required section anchors", () => {
    const doc = readFileSync(SCHEMA, "utf8");
    const anchors = [
      "inbound",
      "outbound",
      "ruleset",
      "route_rule",
      "route_default",
      "dns",
      "dns_server",
      "dns_rule",
      "cache",
      "log",
      "clash_api",
      "subscription",
    ];
    for (const anchor of anchors) {
      const pattern = `## \`${anchor}\``;
      expect(doc).toContain(pattern);
    }
  });

  it("every UCI field accessed in lib/*.uc is documented in uci-schema.md", () => {
    const doc = readFileSync(SCHEMA, "utf8");

    // Read all lib/*.uc files
    const { readdirSync } = require("node:fs") as typeof import("node:fs");
    const libPath = "singbox-ui/root/usr/share/singbox-ui/lib";
    const ucFiles = readdirSync(libPath)
      .filter((f: string) => f.endsWith(".uc"))
      .map((f: string) => readFileSync(`${libPath}/${f}`, "utf8"));
    const combined = ucFiles.join("\n");

    // Strategy A: s_opt/s_num/s_bool("fieldname") — explicit accessor calls
    const strategyA = new Set<string>();
    for (const m of combined.matchAll(
      /s_(?:opt|num|bool)\([a-zA-Z_][a-zA-Z0-9_]*,\s*"([a-z_][a-z0-9_]*)"/g,
    )) {
      strategyA.add(m[1]);
    }

    // Strategy B: direct section.fieldname access on known UCI-section variable names
    const strategyB = new Set<string>();
    for (const m of combined.matchAll(
      /\b(?:s|sec|section|cur|inb|ob|rs|rule|row|node|dns_s)\.([a-z_][a-z0-9_]+)/g,
    )) {
      strategyB.add(m[1]);
    }

    const allFields = new Set([...strategyA, ...strategyB]);
    const missing: string[] = [];

    for (const field of allFields) {
      if (WHITELIST.has(field)) continue;
      if (!doc.includes(`\`${field}\``)) {
        missing.push(field);
      }
    }

    if (missing.length > 0) {
      throw new Error(
        `Fields referenced in lib/*.uc but not documented in ${SCHEMA}:\n  ${missing.join(", ")}`,
      );
    }
  });

  it("C2.1.15: ss_user colon-truncation limitation documented in inbound.uc and uci-schema.md", () => {
    const inbound = readFileSync(
      "singbox-ui/root/usr/share/singbox-ui/lib/inbound.uc",
      "utf8",
    );
    const schema = readFileSync(SCHEMA, "utf8");
    // Must contain a mention of colon or truncat (case-insensitive)
    expect(/colon|truncat/i.test(inbound)).toBe(true);
    expect(/colon|truncat/i.test(schema)).toBe(true);
  });
});
