# Secret Reveal UX

Operators need to occasionally inspect credentials (UUIDs, passwords, reality keys, certificate inline content) without SSHing to the router. By default the RPC layer scrubs all such values to `"***"` (see `lib/scrub.uc::SECRET_KEYS`); this document covers the time-limited bypass introduced in Phase D.

## Mechanism

A short-lived **reveal token** is granted by a write-ACL RPC, persisted on the router filesystem with mode 0600, and consumed by the read-ACL RPCs as an opt-in unscrub trigger. Token TTL is **5 minutes** (`lib/reveal.uc::TTL_SEC`).

```
   ┌──────────────┐                                  ┌──────────────────┐
   │  LuCI user   │   1. click "Show secrets"        │  rpcd (write)    │
   │  (write ACL) │ ─────────────────────────────▶   │  reveal_token_   │
   └──────────────┘                                  │  grant           │
                                                      └──────────────────┘
                                                              │
              2. {token, expires_ts}                          ▼
              ◀────────────────────────────  /var/lib/singbox-ui/reveal_token.json
                                             { "token": "<32 hex>",
                                               "issued_ts": <unix>,
                                               "issued_by": "<luci-user>" }
                                             (root:root, mode 0600)

   ┌──────────────┐   3. read_config(token)          ┌──────────────────┐
   │  Browser     │ ─────────────────────────────▶   │  rpcd (read)     │
   │  (in-memory  │                                  │  maybe_unscrub() │
   │   window.    │                                  │  validates token │
   │   token only)│   4. unscrubbed JSON              │  → bypass scrub │
   └──────────────┘ ◀────────────────────────────    └──────────────────┘
```

## Token storage

| Layer | Location | Lifetime |
|---|---|---|
| **Server (canonical)** | `/var/lib/singbox-ui/reveal_token.json`, root:root, mode 0600 | TTL or until `reveal_token_revoke` is called |
| **Client** | `window.singboxUiRevealToken` (plain JS variable) | Tab lifetime; lost on refresh / navigation |

**The client never writes the token to `localStorage`, `sessionStorage`, or cookies.** `tests/test_view_modules_layout.sh` enforces this invariant — any string matching `localStorage`/`sessionStorage` together with `token`/`singboxUiRevealToken` fails CI.

## RPC surface

| Method | ACL | Purpose |
|---|---|---|
| `reveal_token_grant` | `write.ubus` | Generate a fresh 32-hex-char token, overwrite any existing one, log `event=reveal.granted user=<luci-user>`. Returns `{status, token, expires_ts}`. |
| `reveal_token_revoke` | `write.ubus` | Delete the token file. Returns `{status:"ok"}`. |
| `read_config` | `read.ubus` | Accepts optional `token` arg. With valid token → returns unscrubbed `/tmp/singbox-ui.json`. Otherwise scrubbed (existing C2 behaviour). |
| `export_section` | `read.ubus` | Same, scoped to a single inbound/outbound section. Token forwarded to `export_section.uc` via `REVEAL_TOKEN` env. |
| `preview_config` | `read.ubus` | Same, for the dry-run generated config. |

## Threat model and limitations

- **Router-global token, not per-session.** Anyone with read-ACL who can guess or observe the token (e.g. through MITM on the same LAN) sees unscrubbed credentials for up to 5 minutes. Mitigation: token is 128-bit random, not enumerable; LuCI sessions are HTTPS (when configured); `issued_by` is logged so an audit trail exists.
- **Write-ACL is the gate.** Any user with `write.ubus` already controls the router (can change configs, restart sing-box, push subscriptions). Granting them temporary read of their own credentials is a lateral move, not a privilege escalation.
- **No PAM re-prompt.** Repeat reveal does not require re-authentication. The LuCI session itself is the trust boundary.
- **TTL is fixed at 5 minutes.** No client-side extension; a fresh grant overwrites the previous token (no token accumulation).
- **Server clock authoritative.** Client-side countdown is a UX convenience; if the local clock is wrong, the button may show stale time but the server-side validation uses `time()`.
- **Token survives process restart.** Reveal token persists across rpcd restarts (it lives on disk). A reboot wipes `/var/lib/singbox-ui/` only if mounted on tmpfs (default on most OpenWrt builds), in which case the token is lost — operator must re-grant.

## What is NOT a goal in Phase D

- Per-user / per-session tokens (Phase E candidate).
- Field-level reveal (a single eye-icon next to one secret). Considered and rejected in spec; would require substantial JS rework inside descriptor-driven modals for marginal UX gain.
- Reveal via PAM password challenge instead of write-ACL grant. Could be added later if the write-ACL trust assumption no longer holds.
