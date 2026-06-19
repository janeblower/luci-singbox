import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode, runUcodeJSON } from "../helpers/ucode.ts";

// Port of tests/backend/test_protocol_filler.sh
// Declarative protocol filler (lib/protocols/_filler.uc): field coercion,
// omit rules, json_key rename, UI-only skip, post hook, shared-block dispatch,
// and golden parity for the converted trojan/direct outbound descriptors.

describe("protocol filler", () => {
  useGuest();

  it("flat field coercion + omit + rename + UI-only skip", async () => {
    const src = `
      let filler = require("builder._filler");
      let d = {
        kind: "outbound", sing_box_type: "demo",
        fields: [
          { name: "a",      type: "string", json_key: "a" },
          { name: "ren",    type: "string", json_key: "renamed" },
          { name: "p",      type: "number", json_key: "p", coerce: "num" },
          { name: "keepme", type: "string", json_key: "keepme", omit_when: "never" },
          { name: "flag",   type: "bool",   json_key: "flag", coerce: "bool" },
          { name: "off",    type: "bool",   json_key: "off",  coerce: "bool" },
          { name: "lst",    type: "list",   json_key: "lst",  coerce: "array" },
          { name: "uionly", type: "string" },
        ],
        shared: null,
      };
      let got = filler.build(d, {
        ".name": "tag1",
        a: "hello", ren: "X", p: "42", keepme: "",
        flag: "1", off: "0", lst: [ "h2", "http/1.1" ],
        uionly: "ignored",
      });
      let want = {
        type: "demo", tag: "tag1",
        a: "hello", renamed: "X", p: 42, keepme: "",
        flag: true, lst: [ "h2", "http/1.1" ],
      };
      print(sprintf("%J", got) === sprintf("%J", want) ? "MATCH" : sprintf("MISMATCH got=%J want=%J", got, want));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("MATCH");
  });

  it("omit_when empty drops empty string scalars", async () => {
    const src = `
      let filler = require("builder._filler");
      let d = {
        kind: "outbound", sing_box_type: "demo", shared: null,
        fields: [
          { name: "present", type: "string", json_key: "present" },
          { name: "absent",  type: "string", json_key: "absent"  },
        ],
      };
      let got = filler.build(d, { ".name": "t", present: "v", absent: "" });
      print(got.present === "v" && got.absent == null ? "OK" : sprintf("BAD %J", got));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("post hook runs last and mutates the object", async () => {
    const src = `
      let filler = require("builder._filler");
      let d = {
        kind:"outbound", sing_box_type:"demo", shared:null,
        fields:[ { name:"a", type:"string", json_key:"a" } ],
        post: function(out, s) { out.extra = "added"; },
      };
      let got = filler.build(d, { ".name":"t", a:"v" });
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.type).toBe("demo");
    expect(got.tag).toBe("t");
    expect(got.a).toBe("v");
    expect(got.extra).toBe("added");
  });

  it("shared dispatch: tls merges under out.tls when enabled", async () => {
    const src = `
      let filler = require("builder._filler");
      let got = filler.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_server_name:"example.com" }
      );
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.tls).toBeDefined();
    expect((got.tls as Record<string, unknown>).enabled).toBe(true);
    expect((got.tls as Record<string, unknown>).server_name).toBe(
      "example.com",
    );
  });

  it("shared dispatch: tls disabled -> no tls key", async () => {
    const src = `
      let filler = require("builder._filler");
      let got = filler.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"0" }
      );
      print(got.tls == null ? "NULL" : "PRESENT");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("shared dispatch: tls force_enabled opts passed through", async () => {
    const src = `
      let filler = require("builder._filler");
      let got = filler.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{ force_enabled:true } } },
        { ".name":"t", tls_enabled:"0", tls_server_name:"h2.example" }
      );
      print(got.tls != null && got.tls.enabled === true ? "OK" : sprintf("BAD %J", got));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("shared dispatch: dial merge adds nothing on empty section", async () => {
    const src = `
      let filler = require("builder._filler");
      let got = filler.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ dial:{} } },
        { ".name":"t" }
      );
      // dial is merge-mode; empty dial should not add any extra keys
      let keys = [];
      for (let k in got) push(keys, k);
      print(sprintf("%J", keys));
    `;
    const keys = await runUcodeJSON<string[]>(src);
    // Only type and tag expected when dial is empty
    expect(keys).toContain("type");
    expect(keys).toContain("tag");
    expect(keys).not.toContain("detour");
    expect(keys).not.toContain("bind_interface");
  });

  it("golden parity: trojan outbound via the production dispatcher", async () => {
    // Shell test: server_password is the UCI field for trojan password
    // (maps to json_key "password" in the output JSON via trojan.uc descriptor)
    const src = `
      let ob = require("outbound");
      let s = {
        ".name": "my-trojan",
        server: "1.2.3.4", server_port: "443",
        server_password: "secret",
      };
      let got = ob.build_constructor_for(s, "trojan");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.type).toBe("trojan");
    expect(got.tag).toBe("my-trojan");
    expect(got.server).toBe("1.2.3.4");
    expect(got.server_port).toBe(443);
    expect(got.password).toBe("secret");
  });

  it("golden parity: direct outbound via the production dispatcher", async () => {
    const src = `
      let ob = require("outbound");
      let s = {
        ".name": "my-direct",
        override_address: "8.8.8.8", override_port: "53",
      };
      let got = ob.build_constructor_for(s, "direct");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.type).toBe("direct");
    expect(got.tag).toBe("my-direct");
    expect(got.override_address).toBe("8.8.8.8");
    expect(got.override_port).toBe(53);
  });

  it("golden parity: direct outbound with all override fields empty", async () => {
    const src = `
      let ob = require("outbound");
      let s = { ".name": "bare-direct", override_address: "", override_port: "" };
      let got = ob.build_constructor_for(s, "direct");
      print(sprintf("%J", got));
    `;
    const got = await runUcodeJSON<Record<string, unknown>>(src);
    expect(got.type).toBe("direct");
    expect(got.tag).toBe("bare-direct");
    expect(got.override_address).toBeUndefined();
    expect(got.override_port).toBeUndefined();
  });

  it("registry: a descriptor with fields but no emit registers OK", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"nonemit_t3", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f" } ] });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "OK");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("registry: a descriptor with neither emit nor fields is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try { reg.register({ kind:"outbound", type:"empty_t3", sing_box_type:"x" }); }
      catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  it("registry: emit-less descriptor with an EMPTY fields[] is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"emptyfields_t3", sing_box_type:"x", fields:[] });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  it("registry: a non-function post is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"badpost_t3", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic" } ], post: 7 });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });

  it("validate_field: unknown coerce is rejected", async () => {
    const src = `
      let reg = require("builder.protocols.registry");
      let threw = false;
      try {
        reg.register({ kind:"outbound", type:"badcoerce_t3", sing_box_type:"x",
          fields:[ { name:"f", type:"string", tab:"basic", json_key:"f", coerce:"bogus" } ] });
      } catch (e) { threw = true; }
      print(threw ? "THREW" : "NOTHREW");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("THREW");
  });
});
