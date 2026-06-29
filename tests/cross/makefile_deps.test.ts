import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const SINGBOX_MK = resolve(ROOT, "singbox-ui/Makefile");
const LUCIAPP_MK = resolve(ROOT, "luci-app-singbox-ui/Makefile");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

// Required runtime deps the backend set must carry, in BOTH declarations.
// Mirrors BACKEND_REQUIRED in the old shell test.
const BACKEND_REQUIRED = [
  "bbolt-client",
  "sing-box",
  "curl",
  "ucode",
  "ucode-mod-fs",
  "kmod-nft-socket",
  "kmod-nft-tproxy",
];

/**
 * Normalise a raw dependency string into a sorted, deduplicated set.
 * - Splits on whitespace.
 * - Strips leading '+' (buildroot Makefile syntax).
 * - Drops blank tokens and "libc" (implicit in buildroot; explicit in apk).
 */
function normList(raw: string): string[] {
  return raw
    .split(/\s+/)
    .map((t) => t.replace(/^\+/, ""))
    .filter((t) => t && t !== "libc")
    .sort();
}

/** Extract the first line matching `re` from `file`; throw if not found. */
function grepFirst(file: string, re: RegExp): string {
  for (const line of readFileSync(file, "utf8").split("\n")) {
    const m = line.match(re);
    if (m) return m[1] ?? "";
  }
  throw new Error(`Pattern ${re} not found in ${file}`);
}

// --- Extracted dependency sets (computed once) --------------------------------
//
// Backend Makefile:  `  DEPENDS:=+bbolt-client +sing-box +curl ...`
// Backend build-apk: `SINGBOX_DEPENDS="libc bbolt-client sing-box curl ..."`
// LuCI Makefile:     `LUCI_DEPENDS:=+singbox-ui`  (luci-base is implicit)
// LuCI build-apk:    `LUCIAPP_DEPENDS="libc singbox-ui luci-base"`

function singboxMkSet(): string[] {
  const raw = grepFirst(SINGBOX_MK, /^\s*DEPENDS\s*:?=\s*(.*)$/);
  return normList(raw);
}

function singboxApkSet(): string[] {
  const raw = grepFirst(BUILDSH, /^SINGBOX_DEPENDS="([^"]*)"/);
  return normList(raw);
}

function luciappMkSet(): string[] {
  const raw = grepFirst(LUCIAPP_MK, /^\s*LUCI_DEPENDS\s*:?=\s*(.*)$/);
  // luci-base is implicit via luci.mk — add it to match the .apk side.
  return normList(`${raw} luci-base`);
}

function luciappApkSet(): string[] {
  const raw = grepFirst(BUILDSH, /^LUCIAPP_DEPENDS="([^"]*)"/);
  return normList(raw);
}

// -----------------------------------------------------------------------------

describe("package dependency parity (Makefile <-> build-apk.sh)", () => {
  it("required source files exist", () => {
    for (const f of [SINGBOX_MK, LUCIAPP_MK, BUILDSH]) {
      // readFileSync throws if missing; use a try/catch for a cleaner message
      let ok = true;
      try {
        readFileSync(f);
      } catch {
        ok = false;
      }
      expect(ok).toBe(true);
    }
  });

  // --- nftables / jq must NOT be explicit backend deps ----------------------
  it("nftables is NOT in singbox-ui/Makefile DEPENDS", () => {
    expect(singboxMkSet()).not.toContain("nftables");
  });

  it("nftables is NOT in SINGBOX_DEPENDS (build-apk.sh)", () => {
    expect(singboxApkSet()).not.toContain("nftables");
  });

  it("jq is NOT in singbox-ui/Makefile DEPENDS", () => {
    expect(singboxMkSet()).not.toContain("jq");
  });

  it("jq is NOT in SINGBOX_DEPENDS (build-apk.sh)", () => {
    expect(singboxApkSet()).not.toContain("jq");
  });

  // --- Required backend deps present in BOTH declarations -------------------
  for (const dep of BACKEND_REQUIRED) {
    it(`singbox-ui/Makefile DEPENDS contains '${dep}'`, () => {
      expect(singboxMkSet()).toContain(dep);
    });
    it(`SINGBOX_DEPENDS (build-apk.sh) contains '${dep}'`, () => {
      expect(singboxApkSet()).toContain(dep);
    });
  }

  // --- (a) backend dep SETS are equivalent ----------------------------------
  it("singbox-ui backend dep sets are equivalent (Makefile == build-apk)", () => {
    const mk = singboxMkSet();
    const apk = singboxApkSet();
    expect(apk).toEqual(mk);
  });

  // --- (b) luci-app sets equivalent (Makefile + implicit luci-base) ---------
  it("luci-app-singbox-ui dep sets contain 'singbox-ui' in both", () => {
    expect(luciappMkSet()).toContain("singbox-ui");
    expect(luciappApkSet()).toContain("singbox-ui");
  });

  it("luci-app-singbox-ui dep sets contain 'luci-base' in both", () => {
    expect(luciappMkSet()).toContain("luci-base");
    expect(luciappApkSet()).toContain("luci-base");
  });

  it("luci-app dep sets are equivalent (Makefile+implicit == build-apk)", () => {
    const mk = luciappMkSet();
    const apk = luciappApkSet();
    expect(apk).toEqual(mk);
  });
});
