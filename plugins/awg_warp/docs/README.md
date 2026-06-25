# singbox-ui-plugin-awg_warp

AWG-WARP plugin for `luci-app-singbox-ui`. Adds Cloudflare WARP registration
and AmneziaWG (AWG) obfuscated WireGuard support as a contributed outbound type
`awg_warp`.

## How it works

The plugin contributes a single outbound type (`awg_warp`) that emits a sing-box
`direct` outbound with `bind_interface` pointing at a native ephemeral AWG
interface (`awg0`, `awg1`, …). Cloudflare WARP credentials and AWG obfuscation
parameters are UCI-only — they drive the reconciler but never appear in the
sing-box JSON. Traffic routed through this outbound exits via the AWG interface
and is NATed before leaving the WAN uplink.

## Installation

### 1. Install the plugin package

From the luci-singbox feed (same feed you installed `luci-app-singbox-ui` from):

```
apk add singbox-ui-plugin-awg_warp
```

Or via the LuCI software manager.

### 2. Install AWG components (self-provision)

The plugin does NOT require AmneziaWG kernel modules or tools at install time —
they are self-provisioned at runtime to avoid arch-specific dependency resolution
and to keep the plugin package itself free of external deps.

In LuCI: **Sing-box UI → Outbounds → add AWG WARP outbound → Plugins tab →
"Install AWG + ip-full"** button.

This calls `awg_install` via rpcd, which runs
`root/usr/libexec/singbox-ui/awg-provision.sh`. The script:

1. Reads `/etc/openwrt_release` to detect the OpenWrt version and
   target/subtarget.
2. Fetches the AWG feed signing key dynamically via `wget` and writes it to
   `/etc/apk/keys/` (TOFU — clicking "Install AWG + ip-full" is the trust
   decision).
3. Idempotently adds the AWG feed URL (version + target injected at runtime)
   to `/etc/apk/repositories.d/awg.list`.
4. Runs `apk update` then `apk add ip-full kmod-amneziawg amneziawg-tools`.
5. Runs `modprobe amneziawg` (best-effort).

The script's stdout is suppressed by the rpcd wrapper so the JSON response
stays clean. Errors are printed to stderr and surfaced as `status: "error"`.

You need network access and a compatible OpenWrt 25.12.x target/subtarget.

### 3. Register with Cloudflare WARP

Two modes are supported:

**Auto-register** — click "Register (Cloudflare WARP)" in the outbound form.
The plugin calls the Cloudflare WARP API, creates a new device account, and
stores the credentials (private key, public key, addresses, endpoint) in UCI.

**Paste mode** — if you have an existing `.conf` file exported from the
Cloudflare WARP client, paste it into the "Paste WARP .conf" field. The plugin
parses and stores the credentials.

Both modes write `warp_*` fields to the UCI `singbox-ui` config. These fields
are never emitted to the sing-box JSON.

### 4. Configure the outbound

After registration, configure optional parameters in the outbound form:

| Field | Description |
|---|---|
| Mimic protocol | UDP camouflage for AWG (`auto`, `quic`, `dns`, `stun`, …) |
| Enable IPv6 | Enable IPv6 WARP (auto-masquerade via NAT66) |
| MTU override | Interface MTU; default = WAN MTU − 80 |

Click **"Regenerate (WARP-safe)"** to re-roll the AWG junk parameters
(`Jc`/`Jmin`/`Jmax`/`I1`) without changing WARP credentials. WARP-safe mode
forces `S=0`/`H=1234` (Cloudflare's reserved-byte values).

### 5. Apply and verify

Save and apply the sing-box configuration. The reconciler (`reconcile.uc`)
creates the AWG interface via native `ip`/`awg` commands (not UCI network config)
and installs nftables masquerade rules. The interface is ephemeral — it is
created on start and torn down on stop; it does not appear in `/etc/config/network`.

To check status: **Sing-box UI → Outbounds → AWG WARP outbound → "AWG status"**.

## Architecture notes

- **Interface naming:** `awg<N>` (max 12 chars), derived from the outbound section
  name. All interface names and CIDR values are sanitized before use in `ip`/`nft`
  commands.
- **No double-NAT:** only one `table ip singbox_ui_awg_nat` (v4) and one
  `table ip6 singbox_ui_awg_nat6` (v6) table are created per active outbound.
- **WARP-safe keygen:** `awggen.uc` always forces `S=0`/`H=1234` for WARP mode.
  Self-hosted mode generates random AWG params.
- **Addrlabel:** the reconciler adds a per-interface IPv6 addrlabel entry to
  influence source-address selection.

## File layout

```
plugins/awg_warp/
  Makefile                              OpenWrt/LuCI package definition
  docs/README.md                        This file
  po/
    templates/singbox-ui-plugin-awg_warp.pot   Translatable strings template
    ru/singbox-ui-plugin-awg_warp.po           Russian translation
  lib/                                  → /usr/share/singbox-ui/lib/plugins/awg_warp/
    protocols/awg_warp.uc               Outbound descriptor (emit = direct+bind_interface)
    iface.uc                            Interface name derivation + sanitization
    reconcile.uc                        Native AWG interface lifecycle (ip/awg)
    warp.uc                             Cloudflare WARP registration
    awggen.uc                           AWG key + junk parameter generation
    nft.uc                              nftables masquerade fragment
    init.uc                             Framework discovery entry; registers all hooks + rpcd
  htdocs/                               → www/
    luci-static/resources/view/singbox-ui/plugins/awg_warp/
      tab.js                            LuCI frontend tab (own i18n domain)
  root/                                 → /  (rootfs overlay)
    usr/share/rpcd/acl.d/
      singbox-ui-plugin-awg_warp.json   rpcd ACL (read: awg_status; write: the rest)
    usr/libexec/singbox-ui/
      awg-provision.sh                  Bash self-provision script (fetches AWG feed key + installs)
```

`build-apk.sh` maps `lib/` → `/usr/share/singbox-ui/lib/plugins/awg_warp/`
(recursive, includes `protocols/`), `htdocs/` → `www/`, and `root/` → `/`.
Discovery globs `/usr/share/singbox-ui/lib/plugins/*/init.uc` so `lib/init.uc`
is picked up automatically after installation.
