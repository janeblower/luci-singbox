---
layout: default
title: sing-box-extended apk feed
---

# sing-box-extended apk feed

Signed feed of the [sing-box-extended](https://github.com/shtorm-7/sing-box-extended)
fork, packed as drop-in `sing-box` for OpenWrt (apk).

## Install

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/sing-box-extended/1.13.12_p002004001/$ARCH/packages.adb" \
  > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
```

## Browse

- [1.13.12_p002004001](1.13.12_p002004001/) — packages by architecture
