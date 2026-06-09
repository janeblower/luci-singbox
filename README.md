# luci-app-singbox-ui

LuCI web UI for [sing-box](https://sing-box.sagernet.org/) on OpenWrt
24.10+. Provides a forms-based configuration interface for sing-box
1.12.x — inbounds (tproxy, direct, tun, mixed/socks/http), outbounds
(vless, vmess, trojan, hysteria2, shadowsocks, tuic, anytls, plus
selector/urltest/direct/block/dns), routing, DNS, rule-sets, and
subscriptions. Generates `config.json` directly from UCI sections.

## Highlights

- Native UI for the active sing-box 1.12.x feature set: TLS+ECH,
  multiplex, reality, fragment, hysteria2 brutal/obfs, TUIC, anytls.
- Multi-user vmess/vless/shadowsocks inbounds.
- Share-link parsers for vmess://, vless://, ss://, trojan://, hy2://.
- JSON import and (scrubbed) export per section.
- Subscriptions with the right User-Agent for DDoS-Guarded providers.
- nftables-driven TProxy with atomic table replace.
- Monitoring tab backed by the Clash API.
- Russian translation included.

## Installation (preview)

The package conflicts with the legacy `firewall` package because it
drives nftables directly. See the warning printed by `opkg install`
for details.

## Documentation

See `docs/uci-schema.md`, `docs/protocol-coverage.md`, and
`docs/release.md` for the technical reference.

## fwmark and `ip rule` for TPROXY

The nft ruleset emitted by this package marks packets that should be
intercepted by sing-box's TPROXY socket. The mark value is taken from
the `singbox-ui.@global[0].fwmark` / `fwmark_mask` UCI options
(defaults `0x1` / `0x1`).

For TPROXY to actually route those marked packets to the local socket,
the kernel needs an `ip rule` and a routing table:

```sh
ip -4 rule add fwmark 0x1/0x1 lookup 100
ip -4 route add local default dev lo table 100
ip -6 rule add fwmark 0x1/0x1 lookup 100
ip -6 route add local default dev lo table 100
```

The package does NOT install these rules — they're operator state and
typically come from your `network` UCI config, a startup script, or a
package like `mwan3` / `vpn-policy-routing`. After the package applies
its ruleset it logs a warning to syslog if no matching `ip rule
fwmark…` exists; check `logread -e singbox-ui` after enabling the
tproxy inbound.

To use a different bit (e.g., when mwan3 owns `0xff00`):

```sh
uci set singbox-ui.@global[0].fwmark='0x10000'
uci set singbox-ui.@global[0].fwmark_mask='0x10000'
uci commit singbox-ui
/etc/init.d/singbox-ui restart
```

Then update `ip rule` accordingly. The invariant the validator
enforces: `(fwmark & fwmark_mask) == fwmark`. Violating it falls back
to `0x1 / 0x1` with a log message.

## Redirecting router-originated traffic

By default only LAN-originated traffic is intercepted (the `prerouting`
chain handles it). To also route traffic originated by processes on
the router itself (health checks, OpenVPN clients, etc.) through the
TPROXY socket, set:

```sh
uci set singbox-ui.@global[0].redirect_router_traffic='1'
uci commit singbox-ui
/etc/init.d/singbox-ui restart
```

This adds an `output` chain at `priority mangle` that mirrors the
prerouting decision logic. Disabled by default because router
processes don't usually want to be proxied.

---

(Russian section below — оригинальное описание на русском.)

# luci-app-singbox-ui

LuCI-морда для [sing-box](https://github.com/SagerNet/sing-box) на OpenWrt —
без правки JSON руками, без bash-обвязки, без fw3.

> ⚠️ **Статус: ранняя разработка.** Проект пока сырой — что-то может
> ломаться, API/схема UCI ещё устаканиваются. Если есть предложения,
> хотелки или баг-репорты — заводите
> [issue](../../issues) или PR, буду рад.

## Концепции

- **ucode вместо bash.** Бэкенд (генератор конфига, фетчер подписок,
  эмиттер nftables) — на нативном для OpenWrt `ucode`, а не на shell.
- **Полный контроль без ручного JSON.** Через UCI доступны все основные
  поля inbound/outbound sing-box (multiplex, xhttp/http transports, uTLS,
  ALPN, masquerade и т.д.) — но JSON не пишется руками.
  (если очень хочется писать JSON'ы вручную - кнопка импорта имеется)
- **Прямой nftables, без fw3.** Правила маркировки трафика собираются
  атомарной транзакцией в nft. Пакет конфликтует с `firewall`.
- **Всё через UCI/LuCI.** Один файл `/etc/config/singbox-ui` — источник
  правды. LuCI-страница — форма поверх него с импортом share-link’ов и
  JSON-узлов.
- **Подписки + Clash API live.** Параллельный фетч подписок и rule_set’ов
  с авто-детектом `.srs`/`.json` и кэшем «последнего рабочего». Вкладка
  мониторинга показывает живые соединения через Clash API.

## Установка

Готовые `.apk` лежат в [Releases](../../releases).
Пакет noarch — один и тот же файл подходит любой apk-совместимой сборке
OpenWrt (24.10+).

```sh
apk add --allow-untrusted ./luci-app-singbox-ui_*.apk
# опционально — русский перевод:
apk add --allow-untrusted ./luci-i18n-singbox-ui-ru_*.apk
```

После установки страница появится в **Services → Singbox-UI**.

Сборка из исходников — `scripts/build-apk.sh <version>` поверх OpenWrt SDK.

## Что **не** поддерживается и не планируется поддерживаться с моей стороны.

- **`opkg` / `.ipk`.** Только apk. Старые ветки OpenWrt с opkg — мимо.
- **`fw3` / iptables.** Пакет специально конфликтует с `firewall` и
  совмещаться с ним никогда не будет.

## Планы

1. Допил до полной юзабельности — оставшиеся поля протоколов, UX
   импорта/экспорта, валидация, тесты.
2. **Easy-mode** в духе [podkop](https://github.com/itdoginfo/podkop):
   поверх «полного» интерфейса — упрощённый режим с пресетами и
   импортом подписки одним полем. «Полный» режим при этом остаётся.

## Лицензия

GPL-2.0-or-later.
