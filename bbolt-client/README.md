# bbolt-client

`#![no_std]`, **без libc**, raw-syscall, read-only ридер [bbolt](https://github.com/etcd-io/bbolt)
для кэшей sing-box (`experimental.cache_file`, например `/etc/sing-box/cache.db`
или `/tmp/singbox-ui-cache.db`), собранный с упором на минимальный размер.

Полностью статичные libc-free бинарники: **~7.6 KB** (x86_64) / **~6.2 KB** (aarch64) /
**~6.3 KB** (armv7) / **~9 KB** (mipsel) / **~9 KB** (mips). Сборки mips/mipsel
чуть крупнее (o32-обёртка syscall'ов слегка менее компактна), но всё равно
крошечные — `build.sh` вырезает MIPS-специфичную секцию `.pdr` (procedure-descriptor),
~23 KB non-allocated блоб, который `strip` оставляет на месте и который иначе раздул бы
их до ~32 KB. Каждый бинарник не линкует libc и делает прямые Linux-syscall'ы, поэтому
один статический ELF одинаково работает и на glibc-хостах, и на musl/OpenWrt.

## Сборка (нужен nightly)

    ./build.sh        # -> ./bbolt-client-rs-{x86_64,aarch64,armv7,mipsel,mips}  (+ ./bbolt-client-rs = native)
    make test         # сборка + самодостаточные golden-регрессы

Нужен nightly-тулчейн с `rust-src` (запинен в `rust-toolchain.toml`) и компонентом
`llvm-tools` (даёт `rust-objcopy`, которым `build.sh` срезает `.pdr` на mips). Сборка
использует `-Z build-std=core` с `panic = "immediate-abort"` и линкует через `-nostdlib`,
так что ни libc, ни CRT не подтягиваются; результат — статический ELF без `PT_INTERP`.
Кросс-таргеты линкуются встроенным в тулчейн `rust-lld` — cross-gcc не требуется.

CI собирает все пять архитектур и гоняет тесты (кросс-арки под `qemu-user`)
на каждый push — см. [`.github/workflows/bbolt-client.yml`](../.github/workflows/bbolt-client.yml).
Бинарники выкладываются как артефакты (только бинарь; apk-упаковки пока нет).

**Поддерживаемые арки: x86_64, aarch64, armv7, mipsel (LE), mips (BE) Linux.**
Слой syscall'ов arch-gated (`#[cfg(target_arch)]`: номера syscall'ов + инструкция
`syscall`/`svc` + `_start`); всё остальное архитектурно-независимо и читает on-disk
целые little-endian, так что та же логика бинарника корректна и на big-endian mips.
armv7 — это `target_arch="arm"`; mipsel и mips делят `target_arch="mips"`
(endianness задаёт `target_endian`). Один bbolt-бинарник на семейство покрывает все
CPU-подтипы OpenWrt в этом семействе (float не используется).

## Использование

    bbolt-client-rs <db>                   # список бакетов
    bbolt-client-rs <db> <bucket>          # список ключей в бакете
    bbolt-client-rs <db> <bucket> <key>    # сырые байты значения в stdout
    bbolt-client-rs -r <db> <bucket> <key> # снять обёртку SavedRuleSet -> .srs

Пример — достать кэшированный rule-set и декомпилировать его:

    bbolt-client-rs -r cache.db rule_set warp-telegram-community-ruleset > rs.srs
    sing-box rule-set decompile rs.srs --output rs.json

Открывает read-only с shared-блокировкой и таймаутом ~1с: если файл держит sing-box
(эксклюзивная блокировка), печатает `timeout` (exit 1) вместо зависания — скопируй db
и читай копию. Коды возврата: `0` ok, `1` ошибка (нет файла/бакета/ключа, блокировка),
`2` плохие аргументы. У вывода значения нет завершающего перевода строки.

> Текст OS-ошибки для отсутствующего файла / блокировки / провала mmap упрощён (полная
> таблица errno→строка не стоит байтов). Выводы bucket/key/value/`-r`/usage/
> `no bucket`/`no key`/`timeout` — точные.

### Обёртка SavedRuleSet (`-r`)

Бакет `rule_set` хранит не сырой `.srs`, а sing-box-обёртку `experimental/cachefile`:
`u8 version(==1)`, uvarint-длина контента, сам `.srs`, затем хвостовые метаданные
(`LastUpdated`, `LastEtag`). `-r` валидирует version + длину и отдаёт только контент.
Если формат обёртки изменится в апстриме — правь `unwrap_ruleset`.

### Устойчивость к битому вводу

Битая или обрезанная db репортится как `invalid database` (exit 1) — никогда не краш.
Парсер bounds-чекает page-спаны, отвергает page id, которые переполняются или не
проходят bbolt'овскую self-identity-проверку (`FastCheck`), и ограничивает глубину
спуска по B+tree, так что обрезанная копия или подделанная db (циклические page-ссылки,
заворачивающийся `pgid`, фейковое поле `overflow`) дают чистый exit вместо
SIGSEGV/SIGILL или неверного ответа.

## Как он остаётся маленьким

- Без libc, без CRT: собственный `_start` (через `global_asm!`) + raw-обёртки
  `syscall`/`svc`.
- Без heap'а: db маппится `mmap`'ом `PROT_READ`; ключи/значения — это слайсы в маппинг,
  поэтому `build-std` компилирует только `core` (никакого `alloc`).
- `panic = "immediate-abort"`, `opt-level = "z"`, `lto`, `codegen-units = 1`, strip.
- На mips/mipsel `build.sh` дополнительно вырезает non-allocated `.pdr` через
  `rust-objcopy --remove-section .pdr` (~23 KB, который `strip` не трогает).

## Тесты

`./test.sh` самодостаточен — он сводит вывод бинарника к sha256 и сравнивает с
закоммиченными golden-хэшами в `testdata/golden/` (изначально сняты с апстримного
Go-референса `bbolt` и заморожены). Фикстуры в `testdata/`:

- `cache.db` — настоящий (тонкий) sing-box-кэш, включая путь `-r`.
- `stress.db` — форсит то, чего нет в реальной db: branch-страницы B+tree, overflow-
  страницы (значение 40 KB), inline + вложенные + пустые бакеты, и порядок ключей с
  high-byte.
- `cyclic.db` / `wrap.db` / `overflow.db` — подделанная порча для safety-гардов.

Прогнать aarch64-сборку через тот же набор под qemu:

    RUN="qemu-aarch64 target/aarch64-unknown-linux-gnu/release/bbolt-client-rs" ./test.sh

Фикстуры воспроизводимы через (игнорируемые сборкой) генераторы в `testdata/`:
`gen_stress.go` (нужен Go-модуль с `go.etcd.io/bbolt`) и `gen_corrupt.go`
(только stdlib: `go run testdata/gen_corrupt.go <cyclic|wrap|overflow> <out.db>`). После
изменения фикстуры обнови golden: `./test.sh gen`.
