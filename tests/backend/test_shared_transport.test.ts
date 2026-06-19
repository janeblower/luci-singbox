import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { runUcode } from "../helpers/ucode.ts";

// Port of tests/backend/test_shared_transport.sh
// Declarative emit_spec path via filler for the shared transport block.

describe("shared transport block", () => {
  useGuest();

  it("Test 1: transport_type=none → no transport key", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"none" }
      );
      print(got.transport == null ? "NULL" : "PRESENT");
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("NULL");
  });

  it("Test 2: ws with path + host header", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"ws", transport_path:"/ws",
          transport_host:"ws.example" }
      );
      print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.headers["Host"]));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("ws|/ws|ws.example");
  });

  it("Test 3: grpc — service_name", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"grpc", transport_service_name:"myservice" }
      );
      print(sprintf("%s|%s", got.transport.type, got.transport.service_name));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("grpc|myservice");
  });

  it("Test 4: httpupgrade — path + host", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"httpupgrade", transport_path:"/u",
          transport_host_httpupgrade:"h.example" }
      );
      print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.host));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("httpupgrade|/u|h.example");
  });

  it("Test 5: xhttp with mode", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"xhttp", transport_path:"/x",
          transport_xhttp_mode:"stream-up" }
      );
      print(sprintf("%s|%s|%s", got.transport.type, got.transport.path, got.transport.mode));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("xhttp|/x|stream-up");
  });

  it("Test 6: http — hosts array + path", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ transport:true } },
        { ".name":"t", transport_type:"http",
          transport_hosts:["a.example","b.example"], transport_path:"/h" }
      );
      print(sprintf("%s|%d|%s|%s|%s",
        got.transport.type, length(got.transport.host),
        got.transport.host[0], got.transport.host[1], got.transport.path));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("http|2|a.example|b.example|/h");
  });
});
