import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_registry_robustness.sh
// S4-3 try_register: a malformed descriptor logs+skips instead of aborting.
// S4-4 _shared_module: a broken shared module surfaces a warn(), not silence.
// S4-5 validate_field: enum/values/default consistency is enforced.

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("registry robustness", () => {
  useGuest();

  // ---- S4-3 ----

  it("S4-3: try_register skips malformed descriptor (no throw, no registration)", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.try_register({
          kind: "outbound", type: "broken_s43", sing_box_type: "x",
          fields: [ { name: "f", type: "string" } ],
          emit: function(s) { return {}; },
        });
      } catch (e) { threw = true; }
      print(!threw && reg.get("outbound","broken_s43") == null ? "SKIPPED" : "BAD");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("SKIPPED");
  });

  it("S4-3: plain register() still throws on malformed descriptor", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"strict_s43", sing_box_type:"x",
          fields:[{ name:"f", type:"string" }], emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  // ---- S4-4 ----
  // Create a throwaway lib tree on the guest with a syntactically broken
  // multiplex.uc, then materialize and verify warn() surfaces on stderr.

  it("S4-4: broken shared module surfaces a warn() on stderr", async () => {
    // Build the throwaway dir on the guest, run ucode capturing 2>&1, then clean up.
    const s44dir = `/tmp/s44-${process.pid}`;
    const setup = [
      `rm -rf ${s44dir}`,
      `mkdir -p ${s44dir}/builder/protocols ${s44dir}/builder/_shared`,
      `cp ${LIB}/builder/protocols/registry.uc ${s44dir}/builder/protocols/registry.uc`,
      `cp ${LIB}/helpers.uc ${s44dir}/helpers.uc`,
      // Shadow multiplex.uc with a file that throws on load
      `printf '%s\\n' 'this_symbol_is_not_defined();' > ${s44dir}/builder/_shared/multiplex.uc`,
    ].join(" && ");
    const setupR = await exec(`cd ${WORK} && ${setup}`);
    expect(setupR.exitCode).toBe(0);

    // Write the ucode script to a file to avoid shell quoting issues with single quotes.
    const scriptPath = `${s44dir}/test_s44.uc`;
    const ucodeScript = [
      `let reg = require("builder.protocols.registry");`,
      `reg.register({`,
      `  kind: "outbound", type: "s44", sing_box_type: "x",`,
      `  shared: { multiplex: {} },`,
      `  fields: [ { name: "f", type: "string", tab: "basic" } ],`,
      `  emit: function(s) { return {}; },`,
      `});`,
      `reg.materialize("outbound", "s44");`,
      `print("DONE");`,
    ].join("\n");
    await putFile(ucodeScript, scriptPath);
    const r = await exec(
      `cd ${WORK} && ucode -L ${s44dir} ${scriptPath} 2>&1; rm -rf ${s44dir}`,
    );
    // materialize must still complete (returns null module -> skip block)
    expect(r.stdout).toContain("DONE");
    // Must surface a warning mentioning registry/shared/multiplex
    const combined = r.stdout + r.stderr;
    const warned =
      /registry:.*shared/i.test(combined) ||
      /multiplex/i.test(combined) ||
      /shared module/i.test(combined);
    expect(warned).toBe(true);
  });

  // ---- S4-5 ----

  it("S4-5: enum field without values[] is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45a", sing_box_type:"x",
          fields:[{ name:"e", type:"enum", tab:"basic" }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("S4-5: non-enum field (number) carrying values[] is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45b", sing_box_type:"x",
          fields:[{ name:"n", type:"number", tab:"basic", values:["","1","2"] }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("S4-5: enum default not in values[] is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45c", sing_box_type:"x",
          fields:[{ name:"e", type:"enum", tab:"basic",
                    values:["a","b"], default:"c" }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("S4-5: valid enum with default in values[] is accepted", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45d", sing_box_type:"x",
          fields:[{ name:"e", type:"enum", tab:"basic",
                    values:["","a","b"], default:"a" }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("combobox: list+values[] accepted (datalist suggestions)", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45e", sing_box_type:"x",
          fields:[{ name:"l", type:"list", tab:"basic", values:["a","b"] }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("combobox: string+values[] accepted (datalist suggestions)", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45f", sing_box_type:"x",
          fields:[{ name:"st", type:"string", tab:"basic", values:["a","b"] }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("dynamic selector: unknown discriminator rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45g", sing_box_type:"x",
          fields:[{ name:"d", type:"string", tab:"basic", dynamic:"bogus" }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("dynamic selector: known discriminator (outbounds) accepted", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"s45h", sing_box_type:"x",
          fields:[{ name:"d", type:"string", tab:"basic", dynamic:"outbounds" }],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("BLD-8: requires.field referencing unknown sibling (typo) is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"bld8a", sing_box_type:"x",
          fields:[ { name:"network", type:"string", tab:"basic", json_key:"network" },
                   { name:"pe", type:"string", tab:"basic", json_key:"packet_encoding",
                     requires:{ field:"netwrk", value:"udp" } } ],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("BLD-8: valid sibling requires.field is accepted", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"bld8b", sing_box_type:"x",
          fields:[ { name:"network", type:"string", tab:"basic", json_key:"network" },
                   { name:"pe", type:"string", tab:"basic", json_key:"packet_encoding",
                     requires:{ field:"network", value:"udp" } } ],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("BLD-8: parent_enabled referencing a SHARED-block field is accepted", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"bld8c", sing_box_type:"x",
          shared:{ tls:{} },
          fields:[ { name:"foo", type:"string", tab:"tls", json_key:"foo",
                     parent_enabled:"tls_enabled" } ],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("BLD-8: non-scalar default_when_empty is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"bld8d", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f",
                     default_when_empty:["bad"] } ],
          emit:function(s){return {};} });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });
});
