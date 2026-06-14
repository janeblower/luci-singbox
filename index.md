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
apk update && apk add luci-singbox-ui
```

## Browse

- [OpenWrt 25.12](25.12/) — packages by architecture

Public signing key: [luci-singbox.pem](luci-singbox.pem)

---

Source: [janeblower/luci-singbox](https://github.com/janeblower/luci-singbox)
