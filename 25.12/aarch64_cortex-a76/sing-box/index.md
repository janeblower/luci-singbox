---
layout: default
title: sing-box (aarch64_cortex-a76, OpenWrt 25.12)
---

# sing-box (extended) — aarch64_cortex-a76

Drop-in `sing-box` ([extended fork](https://github.com/shtorm-7/sing-box-extended)) for OpenWrt 25.12.

## Install

```sh
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/25.12/aarch64_cortex-a76/sing-box/packages.adb" \
  > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
```

## Packages

- [sing-box-extended-1.13.14_p002005000.apk](sing-box-extended-1.13.14_p002005000.apk)
- [sing-box-extended-upx-1.13.14_p002005000.apk](sing-box-extended-upx-1.13.14_p002005000.apk)
