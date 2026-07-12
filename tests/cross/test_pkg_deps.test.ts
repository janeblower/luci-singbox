/**
 * tests/cross/test_pkg_deps.test.ts
 *
 * scripts/build-apk.sh — ЕДИНСТВЕННЫЙ источник правды по зависимостям пакетов
 * (OpenWrt-Makefile'ы снесены: docs/release.md — проект apk-only, buildroot-пути нет).
 *
 * Инвариант, ради которого этот файл существует: `nftables` НЕ должен быть в DEPENDS.
 * Он входит в базу OpenWrt через fw4; объявление его зависимостью заставило бы apk
 * тянуть пакет, который уже стоит, и конфликтовать с fw3-совместимым слоем.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const BUILDSH = resolve(ROOT, "scripts/build-apk.sh");

function dependsOf(varName: string): string[] {
  const src = readFileSync(BUILDSH, "utf8");
  const m = src.match(new RegExp(`^${varName}="([^"]*)"`, "m"));
  if (!m) throw new Error(`${varName} not found in build-apk.sh`);
  return m[1].split(/\s+/).filter(Boolean);
}

describe("package dependencies (build-apk.sh is the single source of truth)", () => {
  it("build-apk.sh exists", () => {
    expect(() => readFileSync(BUILDSH, "utf8")).not.toThrow();
  });

  it("SINGBOX_DEPENDS is declared and non-empty", () => {
    expect(dependsOf("SINGBOX_DEPENDS").length).toBeGreaterThan(0);
  });

  it("nftables is NOT in SINGBOX_DEPENDS (it ships in the OpenWrt base via fw4)", () => {
    expect(dependsOf("SINGBOX_DEPENDS")).not.toContain("nftables");
  });

  it("SINGBOX_DEPENDS carries the runtime essentials", () => {
    const deps = dependsOf("SINGBOX_DEPENDS");
    for (const need of ["sing-box", "curl", "ucode", "ucode-mod-fs"])
      expect(deps).toContain(need);
  });

  it("no OpenWrt buildroot Makefile survives (apk-only, per docs/release.md)", () => {
    for (const mk of [
      "singbox-ui/Makefile",
      "luci-app-singbox-ui/Makefile",
      "plugins/awg_warp/Makefile",
    ]) {
      expect(() => readFileSync(resolve(ROOT, mk), "utf8")).toThrow();
    }
  });
});
