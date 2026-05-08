# luci-app-sing-box — ТЗ

## Цель

LuCI-приложение для OpenWrt 25 (современный JS, LuCI2), которое хранит параметры конфигурации sing-box в UCI и генерирует конфиг sing-box на их основе. Первая итерация охватывает: FakeIP, TProxy-инбаунд, nftables-правила и генерацию JSON-конфига в `/tmp`.

---

## Структура пакета

```
luci-app-sing-box/
├── Makefile
├── htdocs/
│   └── luci-static/
│       └── resources/
│           └── view/
│               └── sing-box/
│                   └── main.js              # страница настроек
└── root/
    ├── etc/
    │   ├── config/
    │   │   └── sing-box                     # UCI-конфиг по умолчанию
    │   ├── uci-defaults/
    │   │   └── 99-luci-app-sing-box         # инициализация UCI при первом запуске
    │   └── sing-box/
    │       └── nftables.sh                  # применение/удаление nftables-правил
    └── usr/
        └── share/
            ├── luci/
            │   └── menu.d/
            │       └── luci-app-sing-box.json
            ├── rpcd/
            │   └── acl.d/
            │       └── luci-app-sing-box.json
            └── sing-box/
                └── generate.lua             # генератор JSON-конфига
```

---

## UCI-схема (`/etc/config/sing-box`)

`inet4_range` и `inet6_range` — списки (`list`), поддерживают несколько значений.

```
config fakeip 'fakeip'
    option enabled      '0'
    list   inet4_range  '198.18.0.0/15'
    list   inet6_range  'fc00::/18'

config tproxy 'tproxy'
    option enabled      '0'
    option interface    'br-lan'
    option port         '7893'

config nftables 'nftables'
    option enabled      '0'
```

Все секции — одиночные (один экземпляр каждого типа).

---

## Страница настроек (`main.js`)

Одна страница **Services → Sing-Box** с тремя секциями и кнопкой **«Сгенерировать конфиг»**.

### Раздел 1 — FakeIP

| Поле        | Тип              | UCI-ключ                    | По умолчанию    |
|-------------|------------------|-----------------------------|-----------------|
| Enable      | CheckBox         | `fakeip.fakeip.enabled`     | `0`             |
| IPv4 ranges | DynamicList      | `fakeip.fakeip.inet4_range` | `198.18.0.0/15` |
| IPv6 ranges | DynamicList      | `fakeip.fakeip.inet6_range` | `fc00::/18`     |

`DynamicList` — стандартный виджет LuCI2 (`form.DynamicList`), позволяет добавлять и удалять строки в интерфейсе, сохраняет как UCI `list`.

### Раздел 2 — TProxy Inbound

| Поле        | Тип            | UCI-ключ                  | По умолчанию |
|-------------|----------------|---------------------------|--------------|
| Enable      | CheckBox       | `tproxy.tproxy.enabled`   | `0`          |
| Interface   | ListValue      | `tproxy.tproxy.interface` | `br-lan`     |
| Port        | Value (number) | `tproxy.tproxy.port`      | `7893`       |

`ListValue` для Interface получает список сетевых интерфейсов через `ubus call network.interface dump`.

### Раздел 3 — nftables

| Поле        | Тип      | UCI-ключ                    | По умолчанию |
|-------------|----------|-----------------------------|--------------|
| Enable      | CheckBox | `nftables.nftables.enabled` | `0`          |

Когда включён — при сохранении вызывается `/etc/sing-box/nftables.sh apply`.
При отключении — `/etc/sing-box/nftables.sh remove`.

Вызов скрипта происходит через rpcd (`luci.setInitAction` или отдельный rpcd-метод), без прямого shell-доступа из браузера.

### Кнопка «Сгенерировать конфиг»

Отдельная кнопка на странице (вне формы UCI). По нажатию вызывает rpcd-метод, который запускает `lua /usr/share/sing-box/generate.lua`. Результат (`/tmp/sing-box.json`) не отображается в интерфейсе — только статус «OK» или текст ошибки.

---

## Генерация конфига sing-box (`generate.lua`)

Скрипт на Lua (встроенный интерпретатор OpenWrt, без внешних зависимостей).

**Алгоритм:**

1. Читает UCI через `uci` C-биндинги (доступны в OpenWrt Lua как `require "uci"`).
2. Формирует Lua-таблицу, соответствующую структуре sing-box JSON.
3. Сериализует в JSON с помощью встроенного `require "luci.jsonc"` (входит в `luci-base`).
4. Записывает результат в `/tmp/sing-box.json`.

**Генерируемые секции конфига (первая итерация):**

```json
{
  "dns": {
    "fakeip": {
      "enabled": true,
      "inet4_range": ["198.18.0.0/15"],
      "inet6_range": ["fc00::/18"]
    }
  },
  "inbounds": [
    {
      "type": "tproxy",
      "listen": "::",
      "listen_port": 7893
    }
  ]
}
```

Поля заполняются из UCI. Секции, у которых `enabled = 0`, в конфиг не включаются.

---

## nftables — детали правил (`nftables.sh`)

Скрипт принимает аргумент `apply` или `remove`. Значения читаются из UCI (`uci get sing-box.fakeip.inet4_range` и т.д.).

```nft
table inet sing_box {
    chain prerouting {
        type filter hook prerouting priority mangle; policy accept;

        # FakeIP IPv4 → tproxy
        ip daddr { <inet4_range>, ... } meta l4proto { tcp, udp }
            tproxy ip to 127.0.0.1:<port> mark set 1

        # FakeIP IPv6 → tproxy
        ip6 daddr { <inet6_range>, ... } meta l4proto { tcp, udp }
            tproxy ip6 to [::1]:<port> mark set 1
    }
}
```

При `remove` выполняется `nft delete table inet sing_box`.

---

## rpcd ACL

Методы, доступные через rpcd (роль `luci-app-sing-box`):
- `sing-box.generate` — запуск `generate.lua`
- `sing-box.nftables` — вызов `nftables.sh apply|remove`

---

## Сборка (Makefile)

- `PKG_NAME := luci-app-sing-box`
- Зависимости: `+luci-base`
- Устанавливает файлы через `$(INSTALL_DIR)` / `$(INSTALL_DATA)` / `$(INSTALL_BIN)`

---

## Ограничения первой итерации

- Нет валидации формата CIDR на стороне UI (строка принимается как есть, nftables/sing-box валидируют сами).
- Нет автозапуска/остановки sing-box из интерфейса.
- Конфиг генерируется только в `/tmp/sing-box.json`, дальнейшее применение — вручную.
