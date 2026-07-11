# bbolt-client

Read-only ридер [bbolt](https://github.com/etcd-io/bbolt) для кэшей sing-box
(`experimental.cache_file`, например `/etc/sing-box/cache.db` или
`/tmp/singbox-ui-cache.db`) — **на чистом ucode**, без нативного кода.

Реализация живёт в бэкенд-пакете `singbox-ui`:

- **`singbox-ui/root/usr/share/singbox-ui/lib/bbolt.uc`** — парсер B+tree
  (meta/page/search/walk/uvarint + bounds-checked LE-ридеры). Порт бывшего
  `no_std`/raw-syscall Rust-бинарника 1:1 по поведению; ucode int64 wraps как
  Rust u64 (доказано: FNV-1a64 совпадает с Go байт-в-байт).
- **`singbox-ui/root/usr/libexec/singbox-ui/bbolt-client`** — тонкий CLI-шим
  над `lib/bbolt.uc` (argv-совместим с прежним бинарником). Ставится как часть
  `singbox-ui` (noarch) — отдельного per-arch пакета больше нет.

Этот каталог (`bbolt-client/`) теперь несёт только golden-регресс-харнес:
`test.sh` + `testdata/` (замороженные фикстуры и хэши, снятые с апстримного
Go-референса `bbolt`).

## Использование

    bbolt-client <db>                   # список бакетов
    bbolt-client <db> <bucket>          # список ключей в бакете
    bbolt-client <db> <bucket> <key>    # сырые байты значения в stdout
    bbolt-client -r <db> <bucket> <key> # снять обёртку SavedRuleSet -> .srs

Пример — достать кэшированный rule-set и декомпилировать его:

    bbolt-client -r cache.db rule_set warp-telegram-community-ruleset > rs.srs
    sing-box rule-set decompile rs.srs --output rs.json

Читает весь файл в память (`fs`), никакого mmap. Коды возврата: `0` ok, `1`
ошибка (нет файла/бакета/ключа, битая db), `2` плохие аргументы. У вывода
значения нет завершающего перевода строки.

**Нет flock.** bbolt — copy-on-write с двумя checksummed meta-страницами
(`select_root` берёт валидную с бо́льшим txid), поэтому конкурентный писатель
(sing-box) не может отдать торн-дерево; полуросший файл упирается в bounds-guard
→ чистая ошибка → cron ретраит. Прежний Rust-бинарник брал `LOCK_SH` с таймаутом
~1с; ucode-ридер читает сквозь advisory-lock.

### Обёртка SavedRuleSet (`-r`)

Бакет `rule_set` хранит не сырой `.srs`, а sing-box-обёртку `experimental/cachefile`:
`u8 version(==1)`, uvarint-длина контента, сам `.srs`, затем хвостовые метаданные
(`LastUpdated`, `LastEtag`). `-r` валидирует version + длину и отдаёт только контент.
Если формат обёртки изменится в апстриме — правь `unwrap_ruleset` в `lib/bbolt.uc`.

### Устойчивость к битому вводу

Битая или обрезанная db репортится как `invalid database` (exit 1) — никогда не краш.
Парсер bounds-чекает page-спаны, отвергает page id, которые переполняются или не
проходят bbolt'овскую self-identity-проверку (`FastCheck`), и ограничивает глубину
спуска по B+tree, так что обрезанная копия или подделанная db (циклические page-ссылки,
заворачивающийся `pgid`, фейковое поле `overflow`) дают чистый exit вместо
неверного ответа. Оверфлоу-гарды сделаны в pre-divide форме (`id > len/ps` до
умножения), потому что ucode int64 знаковый и молча заворачивается.

## Тесты

`./test.sh` самодостаточен — сводит вывод шима к sha256 и сравнивает с
закоммиченными golden-хэшами в `testdata/golden/` (сняты с Go-референса `bbolt`
и заморожены). Прогон против ucode-шима:

    LIB=../singbox-ui/root/usr/share/singbox-ui/lib
    SHIM=../singbox-ui/root/usr/libexec/singbox-ui/bbolt-client
    RUN="ucode -L$LIB $SHIM" ./test.sh

В CI это гоняет backend-лейн in-guest (`tests/backend/test_bbolt_golden.test.ts`),
где реальные OpenWrt ucode + ucode-mod-fs гарантированно есть и совпадают с прод.

Фикстуры в `testdata/`:

- `cache.db` — настоящий (тонкий) sing-box-кэш, включая путь `-r`.
- `stress.db` — форсит то, чего нет в реальной db: branch-страницы B+tree, overflow-
  страницы (значение 40 KB), inline + вложенные + пустые бакеты, и порядок ключей с
  high-byte.
- `cyclic.db` / `wrap.db` / `overflow.db` — подделанная порча для safety-гардов.

Фикстуры воспроизводимы через (игнорируемые сборкой) генераторы в `testdata/`:
`gen_stress.go` (нужен Go-модуль с `go.etcd.io/bbolt`) и `gen_corrupt.go`
(только stdlib: `go run testdata/gen_corrupt.go <cyclic|wrap|overflow> <out.db>`). После
изменения фикстуры обнови golden: `RUN="ucode -L$LIB $SHIM" ./test.sh gen`.
