/**
 * tests/cross/test_importer_field_names.test.ts
 *
 * Инвариант: КАЖДОЕ UCI-имя, которое пишут импортёры фронта, обязано быть полем
 * какого-нибудь дескриптора бэкенда.
 *
 * Это шов между пакетами: импортёр живёт в luci-app-singbox-ui, дескрипторы —
 * в singbox-ui, и ни один юнит-тест обе стороны не видит. Импортёры отстали от
 * переименования E2 и продолжали писать до-E2 имена: `security` вместо
 * `tls_enabled`/`reality_enabled`, `transport` вместо `transport_type`,
 * `utls_fingerprint` без парного `utls_enabled`, `vmess_alter_id` вместо
 * `alter_id`, `inbound_user` на vmess вместо `vmess_user`.
 *
 * Симптом был невидимый: вставил `vless://…?security=tls&type=ws`, в
 * сгенерированном JSON НЕТ ни `tls{}`, ни `transport{}`, sing-box дозванивается
 * plaintext-TCP на TLS/ws-эндпоинт, нода мёртвая — а в модалке TLS не отмечен и
 * Transport пуст, то есть «всё нормально». Юниты были зелёные: они утверждали
 * ВЫХОД импортёра, а не то, что потребляет UCI.
 */
import { globSync, readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const ROOT = resolve(import.meta.dirname, "../..");
const BUILDER = resolve(
  ROOT,
  "singbox-ui/root/usr/share/singbox-ui/lib/builder",
);
const IMPORTERS = resolve(
  ROOT,
  "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/importers",
);

// Все `name: "..."` из дескрипторов. Спека `emit_spec` использует те же имена,
// так что один проход по файлу ловит и поля формы, и поля shared-блоков.
function descriptorFields(): Set<string> {
  const out = new Set<string>();
  for (const file of globSync("**/*.uc", { cwd: BUILDER })) {
    const src = readFileSync(resolve(BUILDER, file), "utf8");
    for (const m of src.matchAll(/name:\s*"([A-Za-z_][A-Za-z0-9_]*)"/g))
      out.add(m[1]);
  }
  return out;
}

// `f.foo = ...` / `f["foo"] = ...` в импортёрах. Локальные объекты называются
// f/tf/hf/xf/ssf/fields — одна буквенная приставка на все.
const ASSIGN = /\b(?:f|tf|hf|xf|ssf|vo|fields)\.([A-Za-z_][A-Za-z0-9_]*)\s*=/g;

// Имена, которые НЕ являются полями дескриптора по построению.
const NOT_A_FIELD = new Set([
  // служебные ключи самих импортёров / промежуточного sing-box-объекта
  "ok",
  "errors",
  "fields",
  "value",
  "type", // дискриминатор секции (type у outbound), не поле дескриптора
  "protocol", // он же у inbound
  // ключи промежуточного sing-box JSON, который строит vmess-ветка перед
  // тем, как отдать его в jsonImportOutbound (это JSON, не UCI)
  "transport",
  "tls",
  "uuid",
  "alter_id",
  "security",
  "server_port",
  "server",
  "path",
  "headers",
  "service_name",
  "host",
]);

function importerKeys(file: string): string[] {
  const src = readFileSync(resolve(IMPORTERS, file), "utf8");
  return [...src.matchAll(ASSIGN)].map((m) => m[1]);
}

describe("importers write UCI names the descriptors actually read", () => {
  const known = descriptorFields();

  for (const file of ["outbound.js", "inbound.js", "transport.js"]) {
    it(`${file}: every written option exists in some descriptor`, () => {
      const unknown = [
        ...new Set(importerKeys(file).filter((k) => !NOT_A_FIELD.has(k))),
      ].filter((k) => !known.has(k));
      expect(unknown).toEqual([]);
    });
  }

  it("the pre-E2 names are gone for good", () => {
    // Именно эти пять писались импортёрами и не читаются ничем. Дескрипторных
    // полей с такими именами нет — то есть первый тест их и так поймает; этот
    // называет их вслух, чтобы регресс читался в диффе.
    for (const dead of ["vmess_alter_id"]) expect(known.has(dead)).toBe(false);

    const src = ["outbound.js", "inbound.js", "transport.js"]
      .map((f) => readFileSync(resolve(IMPORTERS, f), "utf8"))
      .join("\n")
      // комментарии объясняют, ПОЧЕМУ старых имён быть не должно
      .replace(/\/\/[^\n]*/g, "");
    expect(src).not.toMatch(/\b(?:f|tf|hf|xf|ssf)\.security\s*=/);
    expect(src).not.toMatch(/\b(?:f|tf|hf|xf|ssf)\.transport\s*=/);
    expect(src).not.toMatch(/\bf\.vmess_alter_id\s*=/);
  });

  it("a fingerprint is never written without utls_enabled", () => {
    // _shared/tls.uc гейтит весь utls-блок на utls_enabled: одинокий
    // utls_fingerprint не эмитит НИЧЕГО.
    const src = readFileSync(resolve(IMPORTERS, "outbound.js"), "utf8");
    const fps = [...src.matchAll(/\.utls_fingerprint\s*=/g)].length;
    const ens = [...src.matchAll(/\.utls_enabled\s*=/g)].length;
    expect(fps).toBeGreaterThan(0);
    expect(ens).toBe(fps);
  });
});
