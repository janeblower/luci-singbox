# singbox-ui-plugin-skeleton

A copy-paste starting point for a luci-app-singbox-ui Phase E plugin.
Mirrors the flat layout used by `plugins/awg_warp/`.

## Quick start

1. Copy this directory to `plugins/<yourname>/` (or a standalone repo).
2. Rename every occurrence of `skeleton` to your plugin name.
   **Plugin names must be underscore-only** (letters, digits, underscores).
   Dashes break ucode's `require()` module resolution.
3. Implement the hooks you need in `lib/init.uc`.
4. Add your outbound/inbound descriptor in `lib/protocols/<name>.uc` and
   uncomment the `require(...)` line in `lib/init.uc`.
5. Update the ACL file at `root/usr/share/rpcd/acl.d/singbox-ui-plugin-<name>.json`
   to list your rpcd method names.
6. Implement your LuCI tab in
   `htdocs/luci-static/resources/view/singbox-ui/plugins/<name>/tab.js`.
7. If your plugin needs external runtime components (kernel modules, helper
   binaries, third-party feeds), adapt `root/usr/libexec/singbox-ui/skeleton-provision.sh`
   and uncomment the `skeleton_install` rpcd wrapper in `lib/init.uc`.
   Otherwise delete the provision script.
8. Build and publish your package to a feed signed with your own key.

## File tree

```
Makefile                                           OpenWrt package definition
lib/
  init.uc                                          Framework discovery entry; calls register({...})
  protocols/
    skeleton.uc                                    Outbound descriptor stub (try_register)
root/
  usr/share/rpcd/acl.d/
    singbox-ui-plugin-skeleton.json                rpcd ACL (read/write split)
  usr/libexec/singbox-ui/
    skeleton-provision.sh                          Optional: self-provision script stub
htdocs/luci-static/resources/view/singbox-ui/plugins/skeleton/
  tab.js                                           LuCI frontend module
```

## build-apk.sh mapping

`build-apk.sh` (used to build `.apk` packages without the OpenWrt buildroot)
maps the source directories as follows:

| Source | Installed at |
|---|---|
| `lib/` | `/usr/share/singbox-ui/lib/plugins/<name>/` (recursive; includes `protocols/`) |
| `htdocs/` | `/www/` (LuCI static serving convention) |
| `root/` | `/` (rootfs overlay) |

The framework discovery mechanism (`discovery.uc`) globs
`/usr/share/singbox-ui/lib/plugins/*/init.uc`, so `lib/init.uc` is found
automatically after installation.

Require-name convention: modules under `lib/` are required as
`plugins.<name>.<mod>` (e.g. `plugins.skeleton.protocols.skeleton`).

## What the skeleton demonstrates

- Registering a no-op of every framework hook (`rpcd`, `lifecycle`, `nft`,
  `on_generate_post`) with explanatory comments.
- How to load an outbound/inbound descriptor (`lib/protocols/skeleton.uc`)
  that calls `builder.protocols.registry.try_register()`.
- The self-provisioning pattern: a bash script at
  `root/usr/libexec/singbox-ui/skeleton-provision.sh` that fetches a feed
  signing key dynamically (TOFU), idempotently adds the feed to its own
  `/etc/apk/repositories.d/<name>.list`, and installs components via `apk add`.
  The rpcd wrapper suppresses the script's stdout so the JSON response stays clean.
- Splitting rpcd methods into read ACL and write ACL.
- Exporting every optional frontend contribution (`tabs`, `outboundTypes`,
  `inboundTypes`, `settingsSections`, `renderOutboundForm`, `mode`) as
  commented stubs.
- A minimal noarch Makefile that depends only on `luci-app-singbox-ui`.

## Publishing

Build the package using the OpenWrt buildroot or `scripts/build-apk.sh`, sign
the index with your own key, and host it on a static server or GitHub Pages.
See `docs/plugins.md` in this repository for the full packaging and
self-provisioning guide.
