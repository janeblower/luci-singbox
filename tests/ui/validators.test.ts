import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci.ts";

const VALIDATORS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/validators.js",
);

// S2-8: track addNotification calls to verify pure-validator contract.
let addNotificationCalls = 0;

const { exports: V, warnings } = loadLuciModule(VALIDATORS, {
  _: (s: unknown) => s,
  L: {
    Class: { extend: (o: unknown) => o },
    ui: {
      addNotification: () => {
        addNotificationCalls++;
      },
    },
  },
  E: (t: unknown) => ({ tag: t }),
});

describe("form validators", () => {
  it("exports the expected validator namespace", () => {
    expect(V).toBeDefined();
    expect(typeof V).toBe("object");
    // port/host are NOT here: descriptors that say validate:"port" / "host"
    // now get LuCI's own datatype (opt.datatype), wired by
    // descriptor_form.js::attachValidator, and exercised against a real
    // rendered form by tests/browser/79-cross-cutting.spec.ts. Only what
    // LuCI has no datatype for stays in this module.
    for (const fn of ["uuid", "url", "alpn"]) {
      expect(typeof V[fn]).toBe("function");
    }
  });

  // --- uuid --------------------------------------------------------------
  describe("uuid", () => {
    it("accepts canonical lowercase UUID", () =>
      expect(V.uuid("550e8400-e29b-41d4-a716-446655440000")).toBe(true));
    it("accepts canonical UPPERCASE UUID", () =>
      expect(V.uuid("550E8400-E29B-41D4-A716-446655440000")).toBe(true));
    it("rejects wrong-length UUID", () =>
      expect(typeof V.uuid("550e8400-e29b-41d4-a716-44665544")).toBe("string"));
    it("rejects UUID without dashes", () =>
      expect(typeof V.uuid("550e8400e29b41d4a716446655440000")).toBe("string"));
    it("rejects UUID with non-hex chars", () =>
      expect(typeof V.uuid("zzzzzzzz-e29b-41d4-a716-446655440000")).toBe(
        "string",
      ));
    it("rejects non-string (number)", () =>
      expect(typeof V.uuid(12345)).toBe("string"));
  });

  // --- url (BUG-1) -------------------------------------------------------
  describe("url", () => {
    it("accepts https URL", () =>
      expect(V.url("https://sub.example.com/config")).toBe(true));
    it("accepts http URL with port", () =>
      expect(V.url("http://1.2.3.4:8080/x")).toBe(true));
    it('rejects empty string ""', () =>
      expect(typeof V.url("")).toBe("string"));
    it("rejects non-string (null)", () =>
      expect(typeof V.url(null)).toBe("string"));
    it("rejects URL without scheme", () =>
      expect(typeof V.url("sub.example.com")).toBe("string"));
    it("rejects ftp:// scheme", () =>
      expect(typeof V.url("ftp://host/x")).toBe("string"));
    it('rejects scheme-only "https://"', () =>
      expect(typeof V.url("https://")).toBe("string"));
  });

  // --- alpn (spec C2.2.3) -------------------------------------------------
  describe("alpn", () => {
    it('accepts ["h2"]', () => expect(V.alpn(["h2"])).toBe(true));
    it('accepts ["h2","http/1.1"]', () =>
      expect(V.alpn(["h2", "http/1.1"])).toBe(true));
    it('accepts ["h3"]', () => expect(V.alpn(["h3"])).toBe(true));
    it('accepts "h2, http/1.1" (string)', () =>
      expect(V.alpn("h2, http/1.1")).toBe(true));
    it("accepts [] (empty allowed)", () => expect(V.alpn([])).toBe(true));
    it('accepts "" (empty allowed)', () => expect(V.alpn("")).toBe(true));
    it("accepts null (empty allowed)", () => expect(V.alpn(null)).toBe(true));
    it('accepts [""] (blank entries ignored)', () =>
      expect(V.alpn([""])).toBe(true));
    it('rejects ["unknown"]', () =>
      expect(typeof V.alpn(["unknown"])).toBe("string"));
    it('rejects ["h2","bogus"]', () =>
      expect(typeof V.alpn(["h2", "bogus"])).toBe("string"));
  });
});
