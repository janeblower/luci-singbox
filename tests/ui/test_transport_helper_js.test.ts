import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci.ts";

// tests/test_transport_helper_js.sh — the transport-parsing block is shared
// (spec S2-QUAL): importers/transport.js exists and both importers route
// transport fields through it identically.

const VIEW_ROOT = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);

const TRANSPORT_JS = resolve(VIEW_ROOT, "importers/transport.js");
const INBOUND_JS = resolve(VIEW_ROOT, "importers/inbound.js");
const OUTBOUND_JS = resolve(VIEW_ROOT, "importers/outbound.js");

describe("transport helper (S2-QUAL)", () => {
  it("importers/transport.js file exists", () => {
    // loadLuciModule would throw if file missing; explicit check mirrors the shell test
    expect(() => readFileSync(TRANSPORT_JS, "utf8")).not.toThrow();
  });

  it("inbound.js requires the shared transport helper", () => {
    const src = readFileSync(INBOUND_JS, "utf8");
    expect(src).toContain("importers.transport");
  });

  it("outbound.js requires the shared transport helper", () => {
    const src = readFileSync(OUTBOUND_JS, "utf8");
    expect(src).toContain("importers.transport");
  });

  describe("parseTransport function", () => {
    const { exports: T } = loadLuciModule(TRANSPORT_JS);

    it("parseTransport is a function", () => {
      expect(typeof T.parseTransport).toBe("function");
    });

    it("http multi-host → transport_hosts array", () => {
      const o = {
        transport: {
          type: "http",
          host: ["a.x", "b.x"],
          path: "/api",
          mode: undefined,
        },
      };
      const fields: Record<string, unknown> = {};
      T.parseTransport(o, fields);
      expect(Array.isArray(fields.transport_hosts)).toBe(true);
      expect((fields.transport_hosts as string[]).length).toBe(2);
    });

    it("http sets transport and transport_path", () => {
      const o = {
        transport: {
          type: "http",
          host: ["a.x", "b.x"],
          path: "/api",
          mode: undefined,
        },
      };
      const fields: Record<string, unknown> = {};
      T.parseTransport(o, fields);
      expect(fields.transport).toBe("http");
      expect(fields.transport_path).toBe("/api");
    });

    it("ws host stays scalar", () => {
      const f2: Record<string, unknown> = {};
      T.parseTransport(
        { transport: { type: "ws", host: "cdn.x", path: "/ws" } },
        f2,
      );
      expect(f2.transport_host).toBe("cdn.x");
      expect(f2.transport).toBe("ws");
    });

    it("xhttp mode is routed", () => {
      const f3: Record<string, unknown> = {};
      T.parseTransport({ transport: { type: "xhttp", mode: "packet-up" } }, f3);
      expect(f3.transport_xhttp_mode).toBe("packet-up");
    });
  });
});
