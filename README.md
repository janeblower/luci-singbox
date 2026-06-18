# cores/sing-box-extended

Standalone build pipeline for [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended).

This **orphan branch** is independent from `main` and is never merged. It contains only
the build pipeline. A scheduled GitHub Actions workflow resolves the latest stable
upstream tag, cross-compiles the fork for our 20 OpenWrt arches (normal + UPX), packs
drop-in `sing-box` apks (`sing-box-extended` / `sing-box-extended-upx`, both
`provides sing-box`), and publishes a signed apk-feed to `gh-pages:/sing-box-extended/`.

## Install on the router

```sh
ARCH=$(apk --print-arch)
wget -O /etc/apk/keys/luci-singbox.pem https://janeblower.github.io/luci-singbox/luci-singbox.pem
echo "https://janeblower.github.io/luci-singbox/sing-box-extended/<ver>/$ARCH/packages.adb" \
  > /etc/apk/repositories.d/sing-box-extended.list
apk update && apk add sing-box-extended      # or sing-box-extended-upx
```

## Files
- `build.sh` — Go cross-compile + `apk mkpkg` (40 apk into a dist dir)
- `feed.sh` — signed feed tree under `sing-box-extended/`
- `.github/workflows/sing-box-extended.yml` — resolve tag, gate, build, smoke, publish
