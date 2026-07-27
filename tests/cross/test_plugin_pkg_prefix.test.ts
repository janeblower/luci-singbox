/**
 * tests/cross/test_plugin_pkg_prefix.test.ts
 *
 * Инвариант: КАЖДЫЙ `pkg:` из tabs/plugins.js начинается с PLUGIN_PKG_PREFIX
 * rpcd-хендлера, и сам префикс совпадает с тем, что реально СОБИРАЕТ
 * build-apk.sh.
 *
 * Константа и её единственный вызыватель живут в разных пакетах (хендлер — в
 * singbox-ui, кнопка — в luci-app-singbox-ui, имя пакета — в scripts/), и это
 * ровно тот шов, где всё сгнило: префикс был `luci-app-singbox-plugin-`, а
 * пакета с таким именем в репозитории никогда не существовало. Каждый клик по
 * «Установить» возвращал "package outside the plugin namespace" ещё до apk, а
 * юнит-тест кормил хендлеру тот же неверный префикс и был зелёный.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const RPCD = resolve(ROOT, "singbox-ui/root/usr/libexec/rpcd/singbox-ui");
const TAB = resolve(
  ROOT,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/plugins.js",
);
const BUILD = resolve(ROOT, "scripts/build-apk.sh");

function prefix(): string {
  const m = readFileSync(RPCD, "utf8").match(
    /const PLUGIN_PKG_PREFIX\s*=\s*"([^"]+)"/,
  );
  if (!m) throw new Error("PLUGIN_PKG_PREFIX not found in the rpcd handler");
  return m[1];
}

function frontendPkgs(): string[] {
  return [...readFileSync(TAB, "utf8").matchAll(/pkg:\s*'([^']+)'/g)].map(
    (m) => m[1],
  );
}

describe("plugin package namespace", () => {
  it("каждый pkg: во фронте лежит в неймспейсе хендлера", () => {
    const p = prefix();
    const pkgs = frontendPkgs();
    expect(pkgs.length).toBeGreaterThan(0);
    expect(pkgs.filter((x) => !x.startsWith(p))).toEqual([]);
  });

  it("префикс совпадает с именем, которое собирает build-apk.sh", () => {
    const m = readFileSync(BUILD, "utf8").match(/AWGWARP_NAME="([^"]+)"/);
    expect(m).toBeTruthy();
    expect(m?.[1].startsWith(prefix())).toBe(true);
  });
});
