import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_filler_v2.sh
describe("filler_v2 (builder._filler primitives)", () => {
  useGuest();

  it("skip_value drops matching scalar", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x",
    fields:[ { name:"network", type:"enum", json_key:"network", skip_value:"tcp" } ], shared:null };
print(sprintf("%J", f.build(d, { ".name":"t", network:"tcp" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe('{ "type": "x", "tag": "t" }');
  });

  it("requires(string) gates on sibling presence", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[
    { name:"plugin", type:"string", json_key:"plugin" },
    { name:"plugin_opts", type:"string", json_key:"plugin_opts", requires:"plugin" },
], shared:null };
print(sprintf("%J", f.build(d, { ".name":"t", plugin_opts:"x" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe('{ "type": "x", "tag": "t" }');
  });

  it("requires({field,value}) gates on sibling value", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[
    { name:"network", type:"enum", json_key:"network", skip_value:"tcp" },
    { name:"packet_encoding", type:"enum", json_key:"packet_encoding", requires:{ field:"network", value:"udp" } },
], shared:null };
print(sprintf("%J", f.build(d, { ".name":"t", network:"tcp", packet_encoding:"xudp" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe('{ "type": "x", "tag": "t" }');
  });

  it("default_when_empty fills constant", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", fields:[
    { name:"proto", type:"enum", json_key:"protocol", default_when_empty:"smux", omit_when:"never" },
], shared:null };
print(sprintf("%J", f.build(d, { ".name":"t" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "x", "tag": "t", "protocol": "smux" }',
    );
  });

  it("group emits nested object when gate passes", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", shared:null, fields:[],
    groups:[ { json_key:"obfs", gate:{ all_present:["obfs_type","obfs_password"] },
               fields:[ { name:"obfs_type", json_key:"type" }, { name:"obfs_password", json_key:"password" } ] } ] };
print(sprintf("%J", f.build(d, { ".name":"t", obfs_type:"salamander", obfs_password:"p" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "x", "tag": "t", "obfs": { "type": "salamander", "password": "p" } }',
    );
  });

  it("group omitted when gate fails", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", shared:null, fields:[],
    groups:[ { json_key:"obfs", gate:{ all_present:["obfs_type","obfs_password"] },
               fields:[ { name:"obfs_type", json_key:"type" }, { name:"obfs_password", json_key:"password" } ] } ] };
print(sprintf("%J", f.build(d, { ".name":"t", obfs_type:"salamander" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe('{ "type": "x", "tag": "t" }');
  });

  it("inbound base builds listen/listen_port", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"inbound", sing_box_type:"mixed", shared:null,
    fields:[ { name:"listen", type:"string" }, { name:"listen_port", type:"number" } ] };
print(sprintf("%J", f.build(d, { ".name":"m", listen_port:"1080" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "mixed", "tag": "m", "listen": "::", "listen_port": 1080 }',
    );
  });

  it("inbound returns null when listen_port missing", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"inbound", sing_box_type:"mixed", shared:null, fields:[] };
print(f.build(d, { ".name":"m" }) == null ? "NULL" : "NOTNULL");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("nested group inside group fields (mutual recursion)", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", shared:null, fields:[],
    groups:[ { json_key:"reality", gate:{ any_present:["pk"] }, fields:[
        { json_key:"enabled", const:true },
        { name:"pk", json_key:"public_key" },
        { json_key:"hs", gate:{ any_present:["srv"] }, fields:[ { name:"srv", json_key:"server" } ] },
    ] } ] };
print(sprintf("%J", f.build(d, { ".name":"t", pk:"K", srv:"e.com" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "x", "tag": "t", "reality": { "enabled": true, "public_key": "K", "hs": { "server": "e.com" } } }',
    );
  });

  it("nested group suppressed when outer gate fails", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x", shared:null, fields:[],
    groups:[ { json_key:"reality", gate:{ any_present:["pk"] }, fields:[
        { json_key:"enabled", const:true },
        { json_key:"hs", gate:{ any_present:["srv"] }, fields:[ { name:"srv", json_key:"server" } ] },
    ] } ] };
print(sprintf("%J", f.build(d, { ".name":"t" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe('{ "type": "x", "tag": "t" }');
  });

  it("registry accepts v2 field props + groups + users", async () => {
    const r = await runUcode(`
let reg = require("builder.protocols.registry");
let threw = false;
try {
    reg.register({ kind:"outbound", type:"v2probe", sing_box_type:"x",
        fields:[ { name:"n", type:"enum", tab:"basic", values:["","tcp","udp"], json_key:"network",
                   skip_value:"tcp", requires:{ field:"n", value:"udp" }, default_when_empty:"smux" } ],
        groups:[ { json_key:"obfs", gate:{ all_present:["a","b"] },
                   fields:[ { name:"a", json_key:"type" } ] } ],
        users:{ from:"u", columns:[ { key:"name", required:true } ] } });
} catch (e) { threw = true; print(sprintf("ERR %s\\n", e)); }
print(threw ? "THREW" : "OK");
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("OK");
  });

  it("filler emits users[] and clears password on multi", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"inbound", sing_box_type:"shadowsocks", shared:null,
    fields:[ { name:"listen", type:"string" }, { name:"listen_port", type:"number" },
             { name:"server_password", type:"string", json_key:"password", omit_when:"never" } ],
    users:{ from:"ss_user",
            columns:[ {key:"name",required:true}, {key:"method",validate:["aes-256-gcm"],discard:true}, {key:"password",tail:true,warn_if_empty:true} ],
            clear_on_multi:["password"] } };
print(sprintf("%J", f.build(d, { ".name":"s", listen_port:"8388", server_password:"root", ss_user:["a:aes-256-gcm:pw"] })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "shadowsocks", "tag": "s", "listen": "::", "listen_port": 8388, "users": [ { "name": "a", "password": "pw" } ] }',
    );
  });

  it("filler keeps top-level password when no multi-users", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"inbound", sing_box_type:"shadowsocks", shared:null,
    fields:[ { name:"listen", type:"string" }, { name:"listen_port", type:"number" },
             { name:"server_password", type:"string", json_key:"password", omit_when:"never" } ],
    users:{ from:"ss_user",
            columns:[ {key:"name",required:true}, {key:"method",validate:["aes-256-gcm"],discard:true}, {key:"password",tail:true,warn_if_empty:true} ],
            clear_on_multi:["password"] } };
print(sprintf("%J", f.build(d, { ".name":"s", listen_port:"8388", server_password:"root" })));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "shadowsocks", "tag": "s", "listen": "::", "listen_port": 8388, "password": "root" }',
    );
  });

  it("only_values drops disallowed, keeps allowed", async () => {
    const r = await runUcode(`
let f = require("builder._filler");
let d = { kind:"outbound", sing_box_type:"x",
    fields:[ { name:"network", type:"enum", json_key:"network", only_values:["tcp","udp"] } ], shared:null };
print(sprintf("%J|%J", f.build(d,{".name":"t",network:"sctp"}), f.build(d,{".name":"t",network:"udp"})));
`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe(
      '{ "type": "x", "tag": "t" }|{ "type": "x", "tag": "t", "network": "udp" }',
    );
  });
});
