# sing-box UI for OpenWrt

LuCI-интерфейс для [sing-box](https://sing-box.sagernet.org/) на OpenWrt —
настройка формами, без правки JSON руками, без bash-обвязки, без fw3.
Бэкенд генерирует `config.json` напрямую из секций UCI.

> ⚠️ **Статус: ранняя разработка (0.1.x).** Проект сырой — что-то может
> ломаться, схема UCI и API ещё устаканиваются. Предложения, хотелки и
> баг-репорты — в [issues](../../issues) или PR, буду рад.

---

## English (summary)

LuCI web UI for [sing-box](https://sing-box.sagernet.org/) on OpenWrt.
Configure inbounds/outbounds with forms — no hand-edited JSON, no bash glue,
no fw3. The backend (written in `ucode`) generates sing-box `config.json`
directly from UCI sections. The full README below is in Russian; the technical
reference in `docs/` is mostly English.

> ⚠️ **Status: early development (0.1.x).** Rough edges expected; the UCI
> schema and RPC API are still settling.

**Features**

- Inbounds: `tproxy`, `mixed` (socks/http), `direct`, plus server-side
  `vless` / `trojan` / `hysteria2` / `shadowsocks`.
- Proxy outbounds: `vless`, `trojan`, `hysteria2`, `shadowsocks`, `direct`,
  with shared TLS (uTLS / ALPN / Reality / ECH), multiplex, transports
  (ws / grpc / http / httpupgrade / xhttp) and dial blocks.
- Share-link import (`vless://`, `ss://`, `trojan://`, `hy2://`), per-section
  JSON import/export (export masks secrets), subscriptions and rule-sets with
  `.srs`/`.json` auto-detect, and live monitoring via the Clash API.
- Russian translation bundled. After install the page appears under
  **Services → Singbox-UI**.

**Install** (OpenWrt 25.12+, apk). The project ships as four packages —
`bbolt-client` (the only per-arch one, ~20 arches), `singbox-ui` (noarch
backend), `luci-app-singbox-ui` (noarch LuCI UI) and `luci-i18n-singbox-ui-ru`
(noarch translation). You install the UI; apk resolves the backend + bbolt as
dependencies. The easiest path is the installer, which detects the arch via
`apk --print-arch`, adds the **signed** GitHub Pages apk feed (repo + signing
key) and runs `apk add`:

```sh
wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
```

**Add the signed apk feed manually** (what the installer automates;
auto-updates with `apk upgrade`):

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru
```

Or install the unsigned release assets manually — grab the four packages from
the [latest release](../../releases) (the per-arch `bbolt-client-<arch>.apk`
plus the three noarch apks) and let apk resolve the order:

```sh
ARCH=$(apk --print-arch)
apk add --allow-untrusted \
  ./bbolt-client-${ARCH}.apk ./singbox-ui.apk \
  ./luci-app-singbox-ui.apk ./luci-i18n-singbox-ui-ru.apk
```

> ⚠️ **Conflicts with `firewall` (fw3).** The `singbox-ui` backend drives
> nftables directly and is meant to *replace* fw3 — its package declares an apk
> conflict with `firewall` and prints a pre-install warning. apk will offer to
> remove `firewall` on install, but confirm nothing else depends on fw3 first;
> if it lingers it will clobber the singbox-ui nftables ruleset on its next
> reload, so stop and remove it yourself if unsure:
>
> ```sh
> /etc/init.d/firewall stop && /etc/init.d/firewall disable
> apk del firewall   # only if nothing else needs fw3
> ```
>
> Only `apk` is supported; there is no `opkg`/`.ipk` build.

> ⚠️ **TPROXY requires an `ip rule` you must add yourself.** The ruleset marks
> packets with `fwmark` (default `0x40000000/0x40000000`, UCI options
> `singbox-ui.@global[0].fwmark` / `fwmark_mask`), but the package does **not**
> install the policy route that delivers them to the local TPROXY socket. Add,
> for both families:
>
> ```sh
> ip -4 rule add fwmark 0x40000000/0x40000000 lookup 100
> ip -4 route add local default dev lo table 100
> ip -6 rule add fwmark 0x40000000/0x40000000 lookup 100
> ip -6 route add local default dev lo table 100
> ```
>
> After applying a ruleset the service logs a warning if no matching
> `ip rule fwmark…` is found — check `logread -e singbox-ui`. See the Russian
> section **«fwmark и `ip rule` для TPROXY»** below for details and how to use a
> different mark bit.
>
> **Per-inbound override:** if a tproxy inbound has UCI `option fwmark` set, that
> value overrides the global mark for that inbound's ruleset — the `ip rule` must
> then use the per-inbound value, not the global one.

---

## Возможности

- **Inbound:** `tproxy`, `mixed` (socks/http), `direct`, а также серверные
  `vless` / `trojan` / `hysteria2` / `shadowsocks`.
- **Outbound (прокси):** `vless`, `trojan`, `hysteria2`, `shadowsocks`,
  `direct`. Маршрутизация, DNS и rule-set’ы — отдельными вкладками.
- **Общие блоки протоколов:** TLS (uTLS / ALPN / Reality / ECH), multiplex,
  транспорты (ws / grpc / http / httpupgrade / xhttp), dial-опции.
- **Импорт share-link:** `vless://`, `ss://`, `trojan://`, `hy2://`
  (с поддержкой IPv6-литералов и секретов с двоеточием).
- **Импорт/экспорт JSON** по секциям; экспорт скрывает секреты.
- **Подписки:** параллельный фетч подписок и rule-set’ов с авто-детектом
  `.srs` / `.json`, лимитом размера тела и кэшем «последнего рабочего»;
  корректный User-Agent для провайдеров за DDoS-Guard.
- **TProxy на nftables** — правила собираются одной атомарной транзакцией
  `nft -f`. Пакет конфликтует с `firewall` (fw3).
- **Мониторинг** живых соединений через Clash API.
- Русский перевод в комплекте.

После установки страница появляется в **Services → Singbox-UI**.

## Концепции

- **ucode вместо bash.** Генератор конфига, фетчер подписок и эмиттер
  nftables написаны на нативном для OpenWrt `ucode`, а не на shell.
- **Полный контроль без ручного JSON.** Через UCI доступны основные поля
  inbound/outbound sing-box (multiplex, транспорты, uTLS, ALPN,
  masquerade и т.д.) — JSON руками писать не нужно. Если очень хочется —
  есть кнопка импорта JSON.
- **Прямой nftables, без fw3.** Маркировка трафика собирается атомарной
  nft-транзакцией; пакет специально конфликтует с `firewall`.
- **Всё через UCI/LuCI.** Один файл `/etc/config/singbox-ui` — источник
  правды; LuCI-страница это форма поверх него с импортом share-link’ов и
  JSON-узлов.
- **Подписки + Clash API.** Авто-детект формата rule-set’ов и кэш рабочей
  версии; вкладка мониторинга показывает соединения в реальном времени.

## Установка

Проект ставится **четырьмя пакетами** (OpenWrt 25.12+, apk): `bbolt-client`
(единственный per-arch, ~20 арок), `singbox-ui` (noarch-бэкенд),
`luci-app-singbox-ui` (noarch LuCI-UI) и `luci-i18n-singbox-ui-ru` (noarch
перевод). Ставишь UI — apk сам подтягивает бэкенд и bbolt как зависимости.
Проще всего через установщик: он определяет арку (`apk --print-arch`),
подключает **подписанный** apk-feed (репозиторий + ключ) и зовёт `apk add`:

```sh
wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
```

**Подключить подписанный apk-feed вручную** (то, что делает установщик;
обновляется через `apk upgrade`):

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru
```

Или поставить неподписанные ассеты релиза вручную — скачай четыре пакета из
[последнего релиза](../../releases) (per-arch `bbolt-client-<arch>.apk` плюс три
noarch-apk) и дай apk разрулить порядок:

```sh
ARCH=$(apk --print-arch)
apk add --allow-untrusted \
  ./bbolt-client-${ARCH}.apk ./singbox-ui.apk \
  ./luci-app-singbox-ui.apk ./luci-i18n-singbox-ui-ru.apk
```

Бэкенд `singbox-ui` **конфликтует с `firewall` (fw3)**, потому что управляет
nftables напрямую и задуман как замена fw3 — пакет объявляет apk-конфликт с
`firewall` и печатает предупреждение перед установкой. apk предложит удалить
`firewall` при установке, но сперва убедитесь, что от fw3 ничего не зависит;
если он останется, на очередном reload затрёт nftables-правила singbox-ui —
тогда остановите и удалите его вручную:

```sh
/etc/init.d/firewall stop && /etc/init.d/firewall disable
apk del firewall   # только если fw3 больше никому не нужен
```

Сборка из исходников — `scripts/build-apk.sh <version>` поверх OpenWrt SDK.

## Что **не** поддерживается (и не планируется)

- **`opkg` / `.ipk`.** Только `apk`. Старые ветки OpenWrt с opkg — мимо.
- **`fw3` / iptables.** Пакет намеренно конфликтует с `firewall` и
  совмещаться с ним не будет.

## fwmark и `ip rule` для TPROXY

Ruleset помечает пакеты, которые должен перехватить TPROXY-сокет sing-box.
Значение метки берётся из UCI-опций `singbox-ui.@global[0].fwmark` /
`fwmark_mask` (по умолчанию `0x40000000` / `0x40000000`).

Чтобы помеченные пакеты дошли до локального сокета, ядру нужны `ip rule` и
таблица маршрутизации:

```sh
ip -4 rule add fwmark 0x40000000/0x40000000 lookup 100
ip -4 route add local default dev lo table 100
ip -6 rule add fwmark 0x40000000/0x40000000 lookup 100
ip -6 route add local default dev lo table 100
```

Пакет эти правила **не** ставит — это состояние оператора (обычно приходит
из `network`-конфига UCI, стартового скрипта или пакетов вроде
`mwan3` / `vpn-policy-routing`). После применения ruleset’а сервис пишет в
syslog предупреждение, если подходящего `ip rule fwmark…` нет — проверяйте
`logread -e singbox-ui` после включения tproxy-inbound.

**Переопределение на уровне inbound:** если у tproxy-inbound выставлена UCI-опция
`option fwmark`, она переопределяет глобальную метку для этого inbound-а — в
этом случае `ip rule` должен использовать именно это значение, а не глобальное.

Другой бит метки (например, если `0xff00` занят mwan3):

```sh
uci set singbox-ui.@global[0].fwmark='0x10000'
uci set singbox-ui.@global[0].fwmark_mask='0x10000'
uci commit singbox-ui
/etc/init.d/singbox-ui restart
```

После этого поправьте `ip rule`. Инвариант, который проверяет валидатор:
`(fwmark & fwmark_mask) == fwmark`; при нарушении — откат к `0x40000000 / 0x40000000`
с записью в лог.

## Перенаправление трафика самого роутера

По умолчанию перехватывается только трафик из LAN (цепочка `prerouting`).
Чтобы пропускать через TPROXY ещё и трафик процессов самого роутера
(health-check’и, OpenVPN-клиенты и т.п.):

```sh
uci set singbox-ui.@global[0].redirect_router_traffic='1'
uci commit singbox-ui
/etc/init.d/singbox-ui restart
```

Добавляется цепочка `output` (`priority mangle`), зеркалящая логику
prerouting. По умолчанию выключено — процессы роутера обычно проксировать
не нужно.

## Запуск тестов

```sh
sh tests/run-vm.sh
```

Поднимает реальный OpenWrt 25.12.3 под QEMU/KVM из заранее собранного
Docker-образа (`ghcr.io/<owner>/luci-singbox/openwrt-test`) и гоняет
backend- и parity-тесты (bun) внутри гостя. На хосте нужны `docker`
и доступный на запись `/dev/kvm` (на GitHub Actions есть из коробки).

Переопределить образ (например, локальный dev-тег из `tests/docker/`):

```sh
SINGBOX_TEST_IMAGE=singbox-test:dev sh tests/run-vm.sh
```

## Документация

Технический справочник — в каталоге `docs/`:
`uci-schema.md` (схема UCI), `protocol-coverage.md` и
`protocol-descriptors.md` (протоколы и дескрипторы), `plugins.md`
(плагины), `release.md` (релизный процесс).

## Планы

1. Допил до полной юзабельности — оставшиеся поля протоколов, UX
   импорта/экспорта, валидация, тесты.
2. **Easy-mode** в духе [podkop](https://github.com/itdoginfo/podkop):
   поверх «полного» интерфейса — упрощённый режим с пресетами и импортом
   подписки одним полем. «Полный» режим при этом остаётся.

## Лицензия

GPL-2.0-or-later.
