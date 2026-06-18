import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_schema_rpc.sh
// Validates singbox-ui::protocol_schema RPC:
//   1. status ok
//   2. version:1 + schema key
//   3. All expected outbound protocols present
//   4. Inbound protocols present within schema.inbound
//   4b. Every protocol entry has tabs[] array
//   5. No literal "function" in response
//   6. At least one "secret":true preserved
//   7. No "emit" key in response
//   8. Dynamic selector sources survive whitelist projection
//   9. tproxy.interface is a persisted dynamic device selector (NOT virtual)
//   9b. BLD-3: per-field min_version reaches the frontend
//  10. No backend-only props leak (json_key, coerce, omit_when, skip_value, requires, default_when_empty)
//  11. tproxy.nft_rules has exclusive:true
//  12. tproxy has a fwmark field

const HANDLER = "singbox-ui/root/usr/libexec/rpcd/singbox-ui";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

// Run the rpcd handler via its prod path (shebang-sensitive file, but we invoke
// explicitly with -L as the shell test does, since shebang isn't available on dev box)
async function callSchema(): Promise<string> {
  const r = await exec(
    `cd ${WORK} && echo '{}' | ucode -L ${LIB} ${HANDLER} call protocol_schema`,
  );
  if (r.exitCode !== 0) {
    throw new Error(
      `handler call failed (exit ${r.exitCode})\nstderr: ${r.stderr}\nstdout: ${r.stdout}`,
    );
  }
  return r.stdout;
}

describe("protocol_schema RPC", () => {
  useGuest();

  let rawResponse: string;

  // Fetch the schema once; subsequent tests reuse it via inline ucode evaluation
  it("1. status ok", async () => {
    rawResponse = await callSchema();
    const parsed = JSON.parse(rawResponse) as Record<string, unknown>;
    expect(parsed.status).toBe("ok");
  });

  it("2. version:1 + schema key present", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const parsed = JSON.parse(rawResponse) as Record<string, unknown>;
    expect(parsed.version).toBe(1);
    expect(parsed.schema).toBeDefined();
  });

  it("3. all expected outbound protocols present in schema", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    // Use ucode to check — exactly as the shell test does with je()
    const r = await runUcode(`
      let fs = require("fs");
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let ob = schema && schema.outbound;
      let expected = ["vless","trojan","hysteria2","shadowsocks","socks"];
      let missing = [];
      for (let p in expected) {
        if (ob == null || ob[p] == null) push(missing, p);
      }
      print(length(missing) === 0 ? "OK" : sprintf("MISSING:%s", join(",", missing)));
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("4. inbound protocols present within schema.inbound", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const inboundProtos = [
      "direct",
      "tproxy",
      "mixed",
      "shadowsocks",
      "vless",
      "trojan",
      "hysteria2",
    ];
    for (const proto of inboundProtos) {
      const r = await runUcode(`
        let j;
        try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
        if (j == null || j.schema == null || j.schema.inbound == null) {
          print("FAIL_NO_INBOUND\\n"); exit(0);
        }
        print(j.schema.inbound[${JSON.stringify(proto)}] == null ? "FAIL_MISSING" : "OK");
      `);
      expect(r.exitCode).toBe(0);
      expect(r.stdout.trim()).toBe("OK");
    }
  });

  it("4b. every protocol entry in schema has tabs[] array", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      if (schema == null) { print("FAIL_NO_SCHEMA"); exit(0); }
      let failures = [];
      for (let kind in ["outbound","inbound"]) {
        let group = schema[kind];
        if (type(group) !== "object") { push(failures, sprintf("no %s", kind)); continue; }
        for (let proto, entry in group) {
          if (type(entry) !== "object") { push(failures, sprintf("%s.%s not object", kind, proto)); continue; }
          if (type(entry.tabs) !== "array") {
            push(failures, sprintf("%s.%s missing tabs[]", kind, proto));
          }
        }
      }
      print(length(failures) === 0 ? "OK" : sprintf("FAIL:%s", join(";", failures)));
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("5. no literal 'function' in response (emit functions stripped)", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    expect(rawResponse.toLowerCase()).not.toContain('"function"');
  });

  it("6. at least one 'secret':true preserved in response", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    expect(rawResponse).toContain('"secret":true');
  });

  it("7. no 'emit' key in response", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    expect(rawResponse).not.toContain('"emit"');
  });

  it("8. dynamic selector sources survive whitelist projection (detour/bind_interface)", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      // Walk all outbound field arrays looking for dynamic:"outbounds" (detour)
      // and dynamic:"interfaces" (bind_interface).
      let found_outbounds = false;
      let found_interfaces = false;
      for (let proto, entry in (schema && schema.outbound)) {
        for (let tab, fields in (entry && entry.tabs)) {
          if (type(fields) !== "array") continue;
          for (let f in fields) {
            if (f.dynamic === "outbounds") found_outbounds = true;
            if (f.dynamic === "interfaces") found_interfaces = true;
          }
        }
      }
      print(found_outbounds && found_interfaces ? "OK" : sprintf("FAIL outbounds:%s interfaces:%s", found_outbounds, found_interfaces));
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("9. tproxy.interface is a persisted dynamic device selector, NOT virtual (de-virtualization fix)", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let tproxy = schema && schema.inbound && schema.inbound.tproxy;
      if (tproxy == null) { print("FAIL_NO_TPROXY"); exit(0); }
      // Walk tproxy tabs looking for "interface" field
      let iface_field = null;
      for (let tab, fields in (tproxy.tabs)) {
        if (type(fields) !== "array") continue;
        for (let f in fields) {
          if (f.name === "interface") { iface_field = f; break; }
        }
        if (iface_field != null) break;
      }
      if (iface_field == null) { print("FAIL_NO_IFACE_FIELD"); exit(0); }
      // Must be dynamic:"devices" and NOT virtual:true
      if (iface_field.dynamic !== "devices") {
        print(sprintf("FAIL_DYNAMIC:%s", iface_field.dynamic)); exit(0);
      }
      if (iface_field.virtual === true) {
        print("FAIL_IS_VIRTUAL"); exit(0);
      }
      print("OK");
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("9b. BLD-3: per-field min_version reaches frontend (ssh.cipher annotated min_version '1.14')", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let ssh = schema && schema.outbound && schema.outbound.ssh;
      if (ssh == null) { print("FAIL_NO_SSH"); exit(0); }
      let cipher_field = null;
      for (let tab, fields in (ssh.tabs)) {
        if (type(fields) !== "array") continue;
        for (let f in fields) {
          if (f.name === "cipher") { cipher_field = f; break; }
        }
        if (cipher_field != null) break;
      }
      if (cipher_field == null) { print("FAIL_NO_CIPHER_FIELD"); exit(0); }
      let mv = cipher_field.min_version;
      if (mv == null) { print("FAIL_NO_MIN_VERSION"); exit(0); }
      // Must be 2-part form (BLD-4 convention)
      let parts = split(mv, ".");
      if (length(parts) !== 2) { print(sprintf("FAIL_NOT_2PART:%s", mv)); exit(0); }
      if (mv !== "1.14") { print(sprintf("FAIL_WRONG:%s", mv)); exit(0); }
      print("OK");
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("10. no backend-only props leak through FIELD_WHITELIST projection", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const backendOnlyKeys = [
      "json_key",
      "coerce",
      "omit_when",
      "skip_value",
      "requires",
      "default_when_empty",
    ];
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let backend_keys = ${JSON.stringify(backendOnlyKeys)};
      let failures = [];
      for (let kind in ["outbound","inbound"]) {
        let group = schema && schema[kind];
        if (type(group) !== "object") continue;
        for (let proto, entry in group) {
          for (let tab, fields in (entry && entry.tabs)) {
            if (type(fields) !== "array") continue;
            for (let f in fields) {
              for (let bk in backend_keys) {
                if (f[bk] != null) {
                  push(failures, sprintf("%s.%s field '%s' has backend-only key '%s'", kind, proto, f.name, bk));
                }
              }
            }
          }
        }
      }
      print(length(failures) === 0 ? "OK" : sprintf("FAIL:%s", join(";", failures)));
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("11. tproxy.nft_rules has exclusive:true", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let tproxy = schema && schema.inbound && schema.inbound.tproxy;
      if (tproxy == null) { print("FAIL_NO_TPROXY"); exit(0); }
      let nft_field = null;
      for (let tab, fields in (tproxy.tabs)) {
        if (type(fields) !== "array") continue;
        for (let f in fields) {
          if (f.name === "nft_rules") { nft_field = f; break; }
        }
        if (nft_field != null) break;
      }
      if (nft_field == null) { print("FAIL_NO_NFT_RULES"); exit(0); }
      print(nft_field.exclusive === true ? "OK" : sprintf("FAIL_exclusive:%J", nft_field.exclusive));
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("12. tproxy has a fwmark field", async () => {
    if (!rawResponse) rawResponse = await callSchema();
    const r = await runUcode(`
      let j;
      try { j = json(${JSON.stringify(rawResponse)}); } catch(_) { print("FAIL_PARSE\\n"); exit(0); }
      let schema = j && j.schema;
      let tproxy = schema && schema.inbound && schema.inbound.tproxy;
      if (tproxy == null) { print("FAIL_NO_TPROXY"); exit(0); }
      let fwmark_field = null;
      for (let tab, fields in (tproxy.tabs)) {
        if (type(fields) !== "array") continue;
        for (let f in fields) {
          if (f.name === "fwmark") { fwmark_field = f; break; }
        }
        if (fwmark_field != null) break;
      }
      print(fwmark_field != null ? "OK" : "FAIL_NO_FWMARK");
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
