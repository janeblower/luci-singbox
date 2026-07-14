/**
 * tests/cross/test_requires_pkg_allowlist.test.ts
 *
 * Инвариант: КАЖДЫЙ `requires_pkg` из дескрипторов обязан быть в
 * INSTALLABLE_PKGS в rpcd-хендлере.
 *
 * Аллоулист — ЭТО валидация (apk идёт под root, имя пакета от клиента до него не
 * доезжает). Дескриптор с `requires_pkg`, которого нет в списке, ломается тихо и
 * ровно в тот момент, когда он нужен: подсказка отрисуется, кнопка «Установить»
 * отрисуется, а `pkg_install` ответит "unknown package" — и юниты этого не
 * увидят, потому что живут по разные стороны шва (дескриптор — в singbox-ui,
 * кнопка — в luci-app-singbox-ui, аллоулист — в rpcd).
 *
 * Прецедент: kmod-nft-queue. tun.auto_redirect ставит nft-правило с выражением
 * `queue`; без kmod'а ядро отвергает ВЕСЬ батч (ENOENT), sing-box падает на
 * post-start, а `sing-box check` при этом зелёный. Подсказка с кнопкой — всё,
 * что стоит между оператором и сервисом, который молча не поднимается.
 */
import { globSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const RPCD = resolve(ROOT, "singbox-ui/root/usr/libexec/rpcd/singbox-ui");
const BUILDER = resolve(
  ROOT,
  "singbox-ui/root/usr/share/singbox-ui/lib/builder",
);

function allowlist(): string[] {
  const src = readFileSync(RPCD, "utf8");
  const m = src.match(/const INSTALLABLE_PKGS\s*=\s*\[([^\]]*)\]/);
  if (!m) throw new Error("INSTALLABLE_PKGS not found in the rpcd handler");
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

// Каждый requires_pkg во всех дескрипторах -> {pkg, файл}.
function declared(): { pkg: string; file: string }[] {
  const out: { pkg: string; file: string }[] = [];
  for (const file of globSync("**/*.uc", { cwd: BUILDER })) {
    const src = readFileSync(resolve(BUILDER, file), "utf8");
    for (const m of src.matchAll(/requires_pkg:\s*"([^"]+)"/g))
      out.push({ pkg: m[1], file });
  }
  return out;
}

describe("requires_pkg <-> INSTALLABLE_PKGS", () => {
  it("каждый requires_pkg дескриптора есть в аллоулисте rpcd", () => {
    const allowed = allowlist();
    const missing = declared()
      .filter((d) => !allowed.includes(d.pkg))
      .map((d) => `${d.file}: ${d.pkg}`);
    expect(missing).toEqual([]);
  });

  it("tun.auto_redirect требует kmod-nft-queue", () => {
    // Не косметика: без kmod'а ядро отвергает весь nft-батч auto_redirect'а и
    // sing-box уходит в respawn-петлю, а `sing-box check` остаётся зелёным.
    const src = readFileSync(resolve(BUILDER, "protocols/tun.uc"), "utf8");
    const field = src.match(/\{\s*name:\s*"auto_redirect"[\s\S]*?\},\n/)?.[0];
    expect(field).toBeTruthy();
    expect(field).toContain('requires_pkg: "kmod-nft-queue"');
  });

  it("auto_route НЕ требует пакета (хватает kmod-tun, он жёсткая зависимость)", () => {
    const src = readFileSync(resolve(BUILDER, "protocols/tun.uc"), "utf8");
    const field = src.match(/\{\s*name:\s*"auto_route"[\s\S]*?\},\n/)?.[0];
    expect(field).toBeTruthy();
    expect(field).not.toContain("requires_pkg");
  });
});
