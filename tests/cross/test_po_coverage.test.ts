import { describe, expect, it } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

// tests/cross/test_po_coverage.sh
// Enforce that po/ru is roughly in sync with JS _('...') sources.
// - Number of msgid entries in po should be within 5 of unique _('...') in JS.
// - At most 5 entries may be untranslated (empty msgstr "").

const REPO = resolve(import.meta.dir, "../..");
const JS_DIR = join(
  REPO,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui",
);
const PO = join(REPO, "luci-app-singbox-ui/po/ru/luci-singbox-ui.po");

/** Recursively collect all .js files under a directory. */
function collectJsFiles(dir: string): string[] {
  const result: string[] = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      result.push(...collectJsFiles(full));
    } else if (entry.endsWith(".js")) {
      result.push(full);
    }
  }
  return result;
}

/**
 * Count unique _('...') / _("...") strings in all JS files under JS_DIR.
 * Reproduces the shell:
 *   grep -rho "_('[^']*')\|_(\"[^\"]*\")" | sort -u | wc -l
 */
function countJsStrings(): number {
  const jsFiles = collectJsFiles(JS_DIR);
  const found = new Set<string>();
  for (const f of jsFiles) {
    const src = readFileSync(f, "utf8");
    // Single-quoted _('...')
    for (const m of src.matchAll(/_\('[^']*'\)/g)) {
      found.add(m[0]);
    }
    // Double-quoted _("...")
    for (const m of src.matchAll(/_\("[^"]*"\)/g)) {
      found.add(m[0]);
    }
  }
  return found.size;
}

/**
 * Count msgid entries in the po file (excluding the empty header msgid "").
 * Reproduces:
 *   grep -c '^msgid ' | minus 1 (for header)
 */
function countPoMsgids(): number {
  const po = readFileSync(PO, "utf8");
  const count = po.split("\n").filter((l) => l.startsWith("msgid ")).length;
  return count - 1; // subtract header msgid ""
}

/**
 * Count untranslated msgstr "" entries (excluding header and continuation-line
 * translations).
 * Reproduces the awk logic:
 *   /^msgstr ""$/ { getline next_line; if (next_line !~ /^"/) print; next }
 */
function countUntranslated(): number {
  const lines = readFileSync(PO, "utf8").split("\n");
  let count = 0;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === 'msgstr ""') {
      // Look at the next line
      const next = lines[i + 1] ?? "";
      if (!next.startsWith('"')) {
        count++;
      }
    }
  }
  return count;
}

describe("po coverage: ru translation in sync with JS sources", () => {
  it("|JS unique _('...')  - po msgid count| <= 5", () => {
    const jsCount = countJsStrings();
    const poCount = countPoMsgids();
    const diff = Math.abs(jsCount - poCount);
    expect(diff).toBeLessThanOrEqual(5);
  });

  it("at most 5 entries are untranslated (empty msgstr '')", () => {
    const untrans = countUntranslated();
    expect(untrans).toBeLessThanOrEqual(5);
  });
});
