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
// Per-file COVERS + source, so the modal-open guard below can verify that the
// SAME file which CLAIMS a grid surface also actually opens its modal.
const files: Array<{ name: string; src: string; covers: string[] }> = [];

for (const f of readdirSync(BROWSER_DIR).filter((n) => /\.mjs$/.test(n))) {
  const src = readFileSync(resolve(BROWSER_DIR, f), "utf8");
  const fileCovers = extractCovers(src);
  files.push({ name: f, src, covers: fileCovers });
  for (const id of fileCovers) {
    if (!ids.has(id)) {
      unknown.push(`${f}: COVERS unknown id "${id}"`);
    }
    covered.add(id);
  }
}

// A `grid.<kind>.<op>` id (op ∈ add|edit) names a modal-spawning surface. Listing
// it in COVERS is NOT enough — the original dns_rule classList crash hid behind a
// COVERS entry whose file never opened the modal. Require the listing file to
// actually call the matching open helper for that kind, so the dangerous render
// path is exercised (runTest() then fails on any pageerror).
function opensModal(src: string, kind: string, op: string): boolean {
  // openAddModal(page, '<kind>', ...) / openEditModal*(page, '<kind>', ...)
  const helper = op === "add" ? "openAddModal" : "openEditModal\\w*";
  const re = new RegExp(`${helper}\\s*\\(\\s*page\\s*,\\s*['"]${kind}['"]`);
  return re.test(src);
}

const gridGaps: string[] = [];
for (const { id } of registry) {
  const parts = id.split(".");
  if (parts[0] !== "grid" || (parts[2] !== "add" && parts[2] !== "edit")) {
    continue;
  }
  const [, kind, op] = parts;
  const listing = files.filter((f) => f.covers.includes(id));
  const exercised = listing.some((f) => opensModal(f.src, kind, op));
  if (listing.length > 0 && !exercised) {
    gridGaps.push(
      `  - ${id}: claimed by [${listing
        .map((f) => f.name)
        .join(", ")}] but none open the modal ` +
        `(expected ${op === "add" ? "openAddModal" : "openEditModal*"}(page, '${kind}', …))`,
    );
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

  it("grid.*.add/edit surfaces are exercised by actually opening the modal", () => {
    expect(
      gridGaps,
      "grid surfaces claimed in COVERS but never opened as a modal " +
        `(listing it is not enough — open it so a render crash is caught):\n${gridGaps.join("\n")}`,
    ).toEqual([]);
  });
});
