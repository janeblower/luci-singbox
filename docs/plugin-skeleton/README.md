# luci-singbox-plugin-skeleton

A copy-paste starting point for a luci-app-singbox-ui Phase E plugin.

## Quick start

1. Copy this entire directory to a new location (e.g. `luci-singbox-plugin-myplugin/`).
2. Rename every occurrence of `skeleton` to your plugin name.  
   **Plugin names must be underscore-only** (letters, digits, underscores).  
   Dashes break ucode's `require()` module resolution.
3. Implement only the hooks you need in `root/usr/share/singbox-ui/lib/plugins/<name>/init.uc`.
4. Update the ACL file at `root/usr/share/rpcd/acl.d/luci-singbox-plugin-<name>.json`
   to list your rpcd method names.
5. Implement your LuCI tab in `htdocs/luci-static/resources/view/singbox-ui/plugins/<name>/tab.js`.
6. Build and publish your package to a feed signed with your own key.

## File tree

```
Makefile                                           OpenWrt package definition
root/
  usr/share/singbox-ui/lib/plugins/skeleton/
    init.uc                                        Backend hook registration
  usr/share/rpcd/acl.d/
    luci-singbox-plugin-skeleton.json              rpcd ACL (read/write split)
htdocs/luci-static/resources/view/singbox-ui/plugins/skeleton/
  tab.js                                           LuCI frontend module
```

## What the skeleton demonstrates

- Registering a no-op of every framework hook (`rpcd`, `lifecycle`, `nft`,
  `on_generate_post`) with explanatory comments.
- Splitting rpcd methods into read ACL and write ACL.
- Exporting every optional frontend contribution (`tabs`, `outboundTypes`,
  `inboundTypes`, `settingsSections`, `renderOutboundForm`, `mode`) as
  commented stubs.
- A minimal noarch Makefile that depends only on `luci-app-singbox-ui`.

## Publishing

Build the package using the OpenWrt buildroot or `build-apk.sh`, sign the
index with your own key, and host it on a static server or GitHub Pages.
See `docs/plugins.md` in the `luci-app-singbox-ui` repo for the full
packaging and self-provisioning guide.
