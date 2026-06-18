---
layout: default
title: luci-singbox APK feed
---

# luci-singbox APK feed

Signed APK package feed for OpenWrt 25.12.x and newer.

## Install via feed

On the router (OpenWrt 25.12.x+, apk-based):

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/luci-singbox/packages.adb" > /etc/apk/repositories.d/luci-singbox.list
apk update && apk add luci-app-singbox-ui
```

## sing-box (extended) core

An extended [sing-box](https://github.com/shtorm-7/sing-box-extended) build is
published as a sibling feed at `25.12/<arch>/sing-box/` (a drop-in
`sing-box` replacement; `-upx` variant available). Optional — install it to
use the extended core:

```sh
ARCH=$(apk --print-arch)
echo "https://janeblower.github.io/luci-singbox/25.12/$ARCH/sing-box/packages.adb" > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
```

## Browse

- [OpenWrt 25.12](25.12/) — packages by architecture (incl. `sing-box/`)

Public signing key: [luci-singbox.pem](luci-singbox.pem)

---

Source: [janeblower/luci-singbox](https://github.com/janeblower/luci-singbox)
