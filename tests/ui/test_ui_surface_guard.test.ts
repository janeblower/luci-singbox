import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

// tests/ui/test_ui_surface_guard.sh — invariant guard for goal (a):
// every interactive element in tests/ui/ui_surface.json MUST be exercised
// by at least one tests/browser/*.mjs declaring it in `export const COVERS = [...]`.

const ROOT = resolve(import.meta.dir, "../..");
const BROWSER_DIR = resolve(ROOT, "tests/browser");
const UI_SURFACE_JSON = resolve(ROOT, "tests/ui/ui_surface.json");

function extractCovers(src: string): string[] {
  const m = src.match(/export\s+const\s+COVERS\s*=\s*\[([\s\S]*?)\]/);
  if (!m) return [];
  return Array.from(m[1].matchAll(/['"]([^'"]+)['"]/g)).map((x) => x[1]);
}

const registry = JSON.parse(readFileSync(UI_SURFACE_JSON, "utf8")) as Array<{
  id: string;
}>;
const ids = new Set(registry.map((e) => e.id));

const covered = new Set<string>();
const unknown: string[] = [];

for (const f of readdirSync(BROWSER_DIR).filter((n) => /\.mjs$/.test(n))) {
  const src = readFileSync(resolve(BROWSER_DIR, f), "utf8");
  for (const id of extractCovers(src)) {
    if (!ids.has(id)) {
      unknown.push(`${f}: COVERS unknown id "${id}"`);
    }
    covered.add(id);
  }
}

describe("ui_surface_guard", () => {
  it("all ui_surface.json ids are covered by at least one browser test", () => {
    const missing = registry.map((e) => e.id).filter((id) => !covered.has(id));
    expect(
      missing,
      `ui_surface ids with NO covering browser test:\n${missing.map((id) => `  - ${id}`).join("\n")}`,
    ).toEqual([]);
  });

  it("all COVERS ids exist in ui_surface.json (no typos)", () => {
    expect(
      unknown,
      `COVERS ids not present in ui_surface.json (typos?):\n${unknown.map((u) => `  - ${u}`).join("\n")}`,
    ).toEqual([]);
  });
});
