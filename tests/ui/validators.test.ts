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
    for (const fn of [
      "isPort",
      "isUuid",
      "isHost",
      "isIPv6Shape",
      "isUrl",
      "validateAlpn",
    ]) {
      expect(typeof V[fn]).toBe("function");
    }
  });

  // --- isPort ----------------------------------------------------------------
  describe("isPort", () => {
    it("accepts 8080 (number)", () => expect(V.isPort(8080)).toBe(true));
    it('accepts "8080" (string)', () => expect(V.isPort("8080")).toBe(true));
    it("accepts 1 (minimum)", () => expect(V.isPort(1)).toBe(true));
    it("accepts 65535 (maximum)", () => expect(V.isPort(65535)).toBe(true));
    it("rejects 0", () => expect(typeof V.isPort(0)).toBe("string"));
    it("rejects 65536", () => expect(typeof V.isPort(65536)).toBe("string"));
    it('rejects "abc"', () => expect(typeof V.isPort("abc")).toBe("string"));
    it("rejects -1", () => expect(typeof V.isPort(-1)).toBe("string"));
    it('rejects ""', () => expect(typeof V.isPort("")).toBe("string"));
  });

  // --- isUuid ----------------------------------------------------------------
  describe("isUuid", () => {
    it("accepts canonical lowercase UUID", () =>
      expect(V.isUuid("550e8400-e29b-41d4-a716-446655440000")).toBe(true));
    it("accepts canonical UPPERCASE UUID", () =>
      expect(V.isUuid("550E8400-E29B-41D4-A716-446655440000")).toBe(true));
    it("rejects wrong-length UUID", () =>
      expect(typeof V.isUuid("550e8400-e29b-41d4-a716-44665544")).toBe(
        "string",
      ));
    it("rejects UUID without dashes", () =>
      expect(typeof V.isUuid("550e8400e29b41d4a716446655440000")).toBe(
        "string",
      ));
    it("rejects UUID with non-hex chars", () =>
      expect(typeof V.isUuid("zzzzzzzz-e29b-41d4-a716-446655440000")).toBe(
        "string",
      ));
    it("rejects non-string (number)", () =>
      expect(typeof V.isUuid(12345)).toBe("string"));
  });

  // --- isHost ----------------------------------------------------------------
  describe("isHost", () => {
    it("accepts IPv4 address", () => expect(V.isHost("1.2.3.4")).toBe(true));
    it("accepts IPv6 address", () =>
      expect(V.isHost("2001:db8::1")).toBe(true));
    it("accepts simple domain", () =>
      expect(V.isHost("example.com")).toBe(true));
    it("accepts subdomain with hyphen", () =>
      expect(V.isHost("a.b-c.example.com")).toBe(true));
    it('rejects empty string ""', () =>
      expect(typeof V.isHost("")).toBe("string"));
    it('rejects string with space "not a host!"', () =>
      expect(typeof V.isHost("not a host!")).toBe("string"));
    it('rejects leading dot ".example.com"', () =>
      expect(typeof V.isHost(".example.com")).toBe("string"));
    it("rejects non-string (null)", () =>
      expect(typeof V.isHost(null)).toBe("string"));

    // INFO-2: tightened IPv6 shape — malformed colon strings now rejected
    it('rejects bare quad colons "::::"', () =>
      expect(typeof V.isHost("::::")).toBe("string"));
    it('rejects too-few groups "1:2:3"', () =>
      expect(typeof V.isHost("1:2:3")).toBe("string"));
    it('rejects 5-digit hex group "12345::1"', () =>
      expect(typeof V.isHost("12345::1")).toBe("string"));
    it('rejects non-hex group "::g1"', () =>
      expect(typeof V.isHost("::g1")).toBe("string"));
    it('rejects double compressor "1::2::3"', () =>
      expect(typeof V.isHost("1::2::3")).toBe("string"));
    it('rejects 9 explicit groups "1:2:3:4:5:6:7:8:9"', () =>
      expect(typeof V.isHost("1:2:3:4:5:6:7:8:9")).toBe("string"));

    // Well-formed IPv6 still passes
    it('accepts loopback "::1"', () => expect(V.isHost("::1")).toBe(true));
    it('accepts "1::"', () => expect(V.isHost("1::")).toBe(true));
    it("accepts full 8-group IPv6 address", () =>
      expect(V.isHost("2001:0db8:0000:0000:0000:ff00:0042:8329")).toBe(true));
    it('accepts compressed "2001:db8::1"', () =>
      expect(V.isHost("2001:db8::1")).toBe(true));
    it('accepts link-local with zone "fe80::1%eth0"', () =>
      expect(V.isHost("fe80::1%eth0")).toBe(true));
  });

  // --- isIPv6Shape -----------------------------------------------------------
  describe("isIPv6Shape", () => {
    it('returns true for "::1"', () => expect(V.isIPv6Shape("::1")).toBe(true));
    it('returns false for "::::"', () =>
      expect(V.isIPv6Shape("::::")).toBe(false));
    it('returns false for "1:2:3"', () =>
      expect(V.isIPv6Shape("1:2:3")).toBe(false));
    it('returns false for string without colon "ffff"', () =>
      expect(V.isIPv6Shape("ffff")).toBe(false));
  });

  // --- isUrl (BUG-1) ---------------------------------------------------------
  describe("isUrl", () => {
    it("accepts https URL", () =>
      expect(V.isUrl("https://sub.example.com/config")).toBe(true));
    it("accepts http URL with port", () =>
      expect(V.isUrl("http://1.2.3.4:8080/x")).toBe(true));
    it('rejects empty string ""', () =>
      expect(typeof V.isUrl("")).toBe("string"));
    it("rejects non-string (null)", () =>
      expect(typeof V.isUrl(null)).toBe("string"));
    it("rejects URL without scheme", () =>
      expect(typeof V.isUrl("sub.example.com")).toBe("string"));
    it("rejects ftp:// scheme", () =>
      expect(typeof V.isUrl("ftp://host/x")).toBe("string"));
    it('rejects scheme-only "https://"', () =>
      expect(typeof V.isUrl("https://")).toBe("string"));
  });

  // --- validateAlpn (spec C2.2.3) -------------------------------------------
  describe("validateAlpn", () => {
    it('accepts ["h2"]', () => expect(V.validateAlpn(["h2"])).toBe(true));
    it('accepts ["h2","http/1.1"]', () =>
      expect(V.validateAlpn(["h2", "http/1.1"])).toBe(true));
    it('accepts ["h3"]', () => expect(V.validateAlpn(["h3"])).toBe(true));
    it('accepts "h2, http/1.1" (string)', () =>
      expect(V.validateAlpn("h2, http/1.1")).toBe(true));
    it("accepts [] (empty allowed)", () =>
      expect(V.validateAlpn([])).toBe(true));
    it('accepts "" (empty allowed)', () =>
      expect(V.validateAlpn("")).toBe(true));
    it("accepts null (empty allowed)", () =>
      expect(V.validateAlpn(null)).toBe(true));
    it('accepts [""] (blank entries ignored)', () =>
      expect(V.validateAlpn([""])).toBe(true));
    it('rejects ["unknown"]', () =>
      expect(typeof V.validateAlpn(["unknown"])).toBe("string"));
    it('rejects ["h2","bogus"]', () =>
      expect(typeof V.validateAlpn(["h2", "bogus"])).toBe("string"));
  });
});
