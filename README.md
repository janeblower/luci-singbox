# luci-singbox-ui

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

**Install** (per-arch `.apk`, OpenWrt 25.12+; the package is built once per
OpenWrt arch — ~20 arches — each embedding the matching `bbolt-client` binary,
so you must install the asset for *your* device's arch, not a wildcard glob).
The easiest path is the installer, which auto-detects the arch via
`apk --print-arch`, downloads the matching `luci-singbox-ui-<arch>.apk` from the
[latest release](../../releases) and verifies its sha256:

```sh
wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
```

Or install a release asset manually — pick the file matching your arch
(`apk --print-arch`):

```sh
ARCH=$(apk --print-arch)
apk add --allow-untrusted ./luci-singbox-ui-${ARCH}.apk
# optional Russian translation (noarch):
apk add --allow-untrusted ./luci-i18n-singbox-ui-ru-*.apk
```

**Or add the signed apk feed** (OpenWrt 25.12+; auto-updates with `apk upgrade`):

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-singbox-ui
```

> ⚠️ **Conflicts with `firewall` (fw3).** This package drives nftables
> directly and is meant to *replace* fw3. The prebuilt `.apk` and `install.sh`
> do **not** declare an apk conflict or auto-remove `firewall`, and neither
> prints a warning — so fw3, if installed, keeps running and will clobber the
> singbox-ui nftables ruleset on its next reload. Before relying on this
> package, stop and remove fw3 yourself and confirm nothing depends on it:
>
> ```sh
> /etc/init.d/firewall stop && /etc/init.d/firewall disable
> apk del firewall   # only if nothing else needs fw3
> ```
>
> Only `apk` is supported; there is no `opkg`/`.ipk` build.

> ⚠️ **TPROXY requires an `ip rule` you must add yourself.** The ruleset marks
> packets with `fwmark` (default `0x1/0x1`, UCI options
> `singbox-ui.@global[0].fwmark` / `fwmark_mask`), but the package does **not**
> install the policy route that delivers them to the local TPROXY socket. Add,
> for both families:
>
> ```sh
> ip -4 rule add fwmark 0x1/0x1 lookup 100
> ip -4 route add local default dev lo table 100
> ip -6 rule add fwmark 0x1/0x1 lookup 100
> ip -6 route add local default dev lo table 100
> ```
>
> After applying a ruleset the service logs a warning if no matching
> `ip rule fwmark…` is found — check `logread -e singbox-ui`. See the Russian
> section **«fwmark и `ip rule` для TPROXY»** below for details and how to use a
> different mark bit.

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

Готовые `.apk` — в [Releases](../../releases). Пакет собирается **по одному
на арку** (~20 арок OpenWrt), в каждый вшит свой бинарь `bbolt-client` — ставить
нужно ассет именно под арку вашего устройства, не по wildcard-маске. Проще всего
через установщик: он сам определяет арку (`apk --print-arch`), качает подходящий
`luci-singbox-ui-<arch>.apk` из последнего релиза и проверяет sha256:

```sh
wget -O- https://raw.githubusercontent.com/janeblower/luci-singbox/main/install.sh | sh
```

Или вручную — выберите ассет под свою арку (`apk --print-arch`):

```sh
ARCH=$(apk --print-arch)
apk add --allow-untrusted ./luci-singbox-ui-${ARCH}.apk
# опционально — русский перевод (noarch):
apk add --allow-untrusted ./luci-i18n-singbox-ui-ru-*.apk
```

**Или подключить подписанный apk-feed** (OpenWrt 25.12+; обновляется через `apk upgrade`):

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-singbox-ui
```

Пакет **конфликтует с `firewall` (fw3)**, потому что управляет nftables
напрямую и задуман как замена fw3. Но готовый `.apk` и `install.sh` **не**
объявляют apk-конфликт, **не** удаляют `firewall` автоматически и **не**
печатают предупреждение — поэтому установленный fw3 продолжит работать и при
очередном reload затрёт nftables-правила singbox-ui. Перед использованием
остановите и удалите fw3 вручную, убедившись, что от него ничего не зависит:

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
`fwmark_mask` (по умолчанию `0x1` / `0x1`).

Чтобы помеченные пакеты дошли до локального сокета, ядру нужны `ip rule` и
таблица маршрутизации:

```sh
ip -4 rule add fwmark 0x1/0x1 lookup 100
ip -4 route add local default dev lo table 100
ip -6 rule add fwmark 0x1/0x1 lookup 100
ip -6 route add local default dev lo table 100
```

Пакет эти правила **не** ставит — это состояние оператора (обычно приходит
из `network`-конфига UCI, стартового скрипта или пакетов вроде
`mwan3` / `vpn-policy-routing`). После применения ruleset’а сервис пишет в
syslog предупреждение, если подходящего `ip rule fwmark…` нет — проверяйте
`logread -e singbox-ui` после включения tproxy-inbound.

Другой бит метки (например, если `0xff00` занят mwan3):

```sh
uci set singbox-ui.@global[0].fwmark='0x10000'
uci set singbox-ui.@global[0].fwmark_mask='0x10000'
uci commit singbox-ui
/etc/init.d/singbox-ui restart
```

После этого поправьте `ip rule`. Инвариант, который проверяет валидатор:
`(fwmark & fwmark_mask) == fwmark`; при нарушении — откат к `0x1 / 0x1`
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
sh tests/run.sh
```

Поднимает реальный OpenWrt 25.12.3 под QEMU/KVM из заранее собранного
Docker-образа (`ghcr.io/<owner>/luci-singbox/openwrt-test`) и гоняет
полный набор ucode- и shell-тестов внутри гостя. На хосте нужны `docker`
и доступный на запись `/dev/kvm` (на GitHub Actions есть из коробки).

Переопределить образ (например, локальный dev-тег из `tests/docker/`):

```sh
SINGBOX_TEST_IMAGE=singbox-test:dev sh tests/run.sh
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
