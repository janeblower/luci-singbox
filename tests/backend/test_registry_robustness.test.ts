import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

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

  // min_version gates EMISSION, and _filler honours it only in _emit_scalar.
  // On a `const` or a group entry it is silently ignored — the key still reaches
  // a core that does not know it, which refuses the whole config. Registration is
  // where that mistake is made, so registration is where it must fail.

  it("min_version on a GROUP entry is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"vgate_a", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ],
          groups:[ { json_key:"ech", min_version:"1.13",
                     fields:[ { name:"g", json_key:"config" } ] } ] });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("min_version on a CONST entry (nested in a group) is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"vgate_b", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ],
          groups:[ { json_key:"ech", fields:[
                     { json_key:"enabled", const:true, min_version:"1.13" } ] } ] });
      } catch (e) { threw = true; }
      print(threw ? "REJECTED" : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
  });

  it("min_version on a SCALAR group field is accepted (that one _filler honours)", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = "";
      try {
        reg.register({ kind:"outbound", type:"vgate_c", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ],
          groups:[ { json_key:"ech", fields:[
                     { name:"g", json_key:"config", min_version:"1.13" } ] } ] });
      } catch (e) { threw = "" + e; }
      print(length(threw) ? threw : "ACCEPTED");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ACCEPTED");
  });

  it("a SHARED block's emit_spec is validated too (min_version on its group)", async () => {
    // The trap the assertion exists for lives in a shared block (tls.uc's `ech`
    // group), and nothing validated emit_spec at all before. Shadow multiplex.uc
    // with a spec that puts min_version on a group entry: register() must throw.
    const dir = `/tmp/vgate-${process.pid}`;
    const spec = [
      "return {",
      '  applies_to: { kinds: ["outbound"] },',
      '  fields: [ { name: "mux_enabled", type: "bool", tab: "mux" } ],',
      "  emit_spec: { seq: [",
      '    { json_key: "brutal", min_version: "1.13",',
      '      fields: [ { name: "mux_enabled", json_key: "enabled", coerce: "bool" } ] },',
      "  ] },",
      "};",
    ].join("\n");
    const drv = [
      'let reg = require("builder.protocols.registry");',
      "let threw = false;",
      "try {",
      '  reg.register({ kind:"outbound", type:"vgate_d", sing_box_type:"x",',
      "    shared:{ multiplex:{} },",
      '    fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ] });',
      "} catch (e) { threw = true; }",
      'print(threw ? "REJECTED" : "ACCEPTED");',
    ].join("\n");
    await exec(`rm -rf ${dir} && mkdir -p ${dir}/builder/_shared`);
    await putFile(spec, `${dir}/builder/_shared/multiplex.uc`);
    await putFile(drv, `${dir}/drv.uc`);
    // First -L wins: the fake multiplex shadows the real one, everything else
    // resolves against the production lib.
    const r = await exec(
      `cd ${WORK} && ucode -L ${dir} -L ${LIB} ${dir}/drv.uc; rc=$?; rm -rf ${dir}; exit $rc`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("REJECTED");
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

  // F4: _filler.build() (mirrored in _unfiller.field_names/parse) branches on
  // `d.shared != null && d.shared.listen` to decide whether an inbound gets
  // build_listen_base's {listen, listen_port} header. Before cde028ae every
  // kind:"inbound" descriptor got that header unconditionally (the flag was
  // effectively "am I an inbound"); now it is load-bearing, and it fails OPEN —
  // a listener descriptor that forgets to declare shared.listen silently builds
  // a bare {type,tag}, with no way for the user to set listen/listen_port, and
  // nothing catches it until init.d's `sing-box check` refuses to start.
  //
  // This guard is vacuous today: every real listener already declares its own
  // local `listen_port` UI field (build_listen_base reads it straight off raw
  // UCI — it has no json_key of its own) paired with shared.listen. It exists
  // to catch the NEXT descriptor that breaks that pairing in either direction:
  // a re-introduced local listen_port field without the shared block, or an
  // existing listener whose shared.listen gets dropped while its listen_port
  // field is left behind (the field is what this check keys on, so either
  // mistake trips it).
  it("F4: every inbound descriptor with a listen_port field also declares shared.listen", async () => {
    const src = `
      require("outbound");
      require("inbound");
      let reg = require("builder.protocols.registry");
      let bad = [];
      for (let ctx in reg._registry) {
          let d = reg._registry[ctx];
          if (d.kind !== "inbound") continue;
          let has_listen_port = false;
          for (let f in (d.fields || [])) if (f.name === "listen_port") has_listen_port = true;
          let has_shared_listen = d.shared != null && d.shared.listen;
          if (has_listen_port && !has_shared_listen) push(bad, ctx);
      }
      for (let b in sort(bad)) print(sprintf("BAD %s\\n", b));
      print(length(bad) ? "FAIL\\n" : "OK\\n");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });
});
