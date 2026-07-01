# Protocol Descriptors

(Phase E2 DSL — registry-only model.)

## Concept

Every UI-creatable protocol is described by a declarative **descriptor**: a
single file under `lib/builder/protocols/<name>.uc` that registers itself with the
central registry (`lib/builder/protocols/registry.uc`) on load. One module may register
both the outbound and the inbound side of the same protocol. The descriptor
carries:

- `kind`: `"inbound"` or `"outbound"`
- `type`: UCI type tag (for outbounds this is the `type` option; for inbounds
  the `protocol` option — e.g. `"trojan"`)
- `sing_box_type`: the value sing-box expects in the JSON `"type"` field
- `shared`: a map declaring which shared blocks the protocol composes with
  (`{ tls: {}, transport: {}, multiplex: {}, dial: true }`) — the registry
  merges each block's fields in at `materialize()` time
- `fields[]`: declarative field list (see the field vocabulary below)
- per-field emission metadata (`json_key`, plus `coerce` / `omit_when` /
  `groups` / `users`): `builder/_filler.uc` assembles the sing-box JSON object
  from this and the declared shared blocks. An `emit(section)` function is an
  **optional** escape-hatch that overrides the filler for the few descriptors
  needing bespoke logic (returning `null` skips the section)

## How dispatch works

After Phase E2 there is no hand-coded switch-by-type fallback at all.
`lib/outbound.uc` and `lib/inbound.uc` dispatch purely through the registry:

- `lib/outbound.uc::build_constructor_for(s, proto)` calls `reg.get("outbound",
  proto)` and builds the section via
  `type(d.emit) === "function" ? d.emit(s) : filler.build(d, s)` — i.e. the
  declarative `builder/_filler.uc`, unless the descriptor carries an escape-hatch
  `emit()`. If no descriptor is registered for the pair it logs `no descriptor
  for '<proto>'` and returns `null` — there is no hand-coded fallback.
- `lib/inbound.uc::build_one` is the same: it looks the descriptor up via
  `reg.get("inbound", s.protocol)` and builds it the same way (`filler.build(d,
  s)` unless the descriptor sets `emit`), or logs `no descriptor for '<proto>'`
  and returns `null`. The infrastructure inbound
  types (`tproxy`, `mixed`, `direct`) are themselves descriptors
  (`lib/builder/protocols/{tproxy,mixed,direct}.uc`), not hand-coded branches.

`lib/outbound.uc` eagerly `require()`s every active descriptor module at load
time so each `register()` call fires. Each require is wrapped in try/catch so a
single malformed descriptor file logs and is skipped (`try_register` =
log+skip, never abort) instead of taking down config generation for all
protocols. The eager require-list in `lib/outbound.uc` names every active
outbound descriptor module in the `builder.protocols.*` namespace, e.g.:

```
builder.protocols.direct
builder.protocols.shadowsocks
builder.protocols.vless
builder.protocols.trojan
builder.protocols.hysteria2
builder.protocols.json_raw
```

(the live list also covers the remaining proxy descriptors — `tuic`, `anytls`,
`shadowtls`, `socks`, `http`, `vmess`, `naive`, the `groups` selector/urltest,
etc.; `lib/outbound.uc` is the single source of truth). Anything not in that
list is permanently absent from the UI and the generated JSON. `lib/inbound.uc`
has its own analogous eager require-list (it additionally loads the inbound-only
`builder.protocols.tproxy` and `builder.protocols.mixed` infrastructure
descriptors, plus `builder.protocols.redirect` and `builder.protocols.cloudflared`).

## Writing a descriptor

Use a shipped descriptor as a template. Descriptors are now **fully
declarative**: there is no hand-written `emit()` — `builder/_filler.uc` assembles
the sing-box JSON from each field's emission metadata (`json_key` + `coerce` /
`omit_when` / `skip_value` / `requires` / `groups` / `users`) plus the declared
shared blocks. The Trojan outbound (`lib/builder/protocols/trojan.uc`) is a
compact example:

```ucode
// lib/builder/protocols/trojan.uc
let reg = require("builder.protocols.registry");

reg.register({
    kind: "outbound", type: "trojan", sing_box_type: "trojan",
    shared: { tls: {}, transport: {}, multiplex: {}, dial: true },

    fields: [
        { name: "server", type: "string", tab: "basic", required: true,
          validate: "host", ui_label: "Server",
          json_key: "server", omit_when: "never" },
        { name: "server_port", type: "number", tab: "basic", required: true,
          validate: "port", ui_label: "Server port", default: 443,
          json_key: "server_port", coerce: "num", omit_when: "never" },
        { name: "server_password", type: "string", tab: "basic", required: true,
          secret: true, ui_label: "Password",
          json_key: "password" },
    ],
    // No emit(): builder._filler builds {type,tag} + the three fields above +
    // the declared tls/transport/multiplex/dial shared blocks, byte-identical to
    // the former hand-written emit().
});

return {};
```

The emission props on each scalar field drive the filler:

- `json_key` — opt-in write key. A field **without** `json_key` is UI-only and
  never reaches the generated config.
- `coerce: str|num|bool|array|num_array` — value type in the emitted JSON.
- `omit_when: empty|never` — `never` always writes the key; the default omits it
  when the value is empty. `skip_value` / `requires` / `default_when_empty` gate
  conditional emission.
- `groups: [{ json_key, gate, fields }]` — nested JSON objects.
- `users: { from?, columns[], single_fallback? }` — the multi-user builder
  (`builder/_shared/users.uc`). The Trojan **inbound** register uses a
  `single_fallback` to fold `server_password` into a one-element `users` array.
- Shared blocks (`tls`/`transport`/`multiplex`/`dial`/`quic`) each export an
  `emit_spec` the filler consumes; declaring them in `shared` is all that is
  needed.

An `emit(section)` function survives only as an **optional escape-hatch** for the
few descriptors that still need bespoke logic; the dispatcher runs it only when
present (`type(d.emit) === "function" ? d.emit(s) : filler.build(d, s)`),
otherwise the filler builds the section. A descriptor may also carry an optional
`post(out, s)` for a final tweak.

To add a new protocol:

1. Create `lib/builder/protocols/<name>.uc` with one or two `reg.register({...})` calls.
2. Add the module to the eager require-list near the top of `lib/outbound.uc`
   (outbound side) — inbound-only modules are loaded by `lib/inbound.uc`.
3. Add the file to `scripts/install-manifest.txt` (regenerated by
   `scripts/gen-manifest.sh`).

`register()` validates the descriptor strictly (it asserts on a malformed
`field`, unknown `shared` key, or enum/`values` mismatch). Built-in callers use
`register()`; the plugin / bring-up paths use `try_register()` which logs and
skips instead of throwing.

## Field type vocabulary

`field.type` must be one of (`KNOWN_TYPES` in `registry.uc`):

- `string` — free-text input. May carry `values` (datalist suggestions — free
  entry is retained, **not** a strict whitelist).
- `number` — numeric input. May **not** carry `values`.
- `bool` — `0`/`1` toggle. May **not** carry `values`.
- `enum` — strict dropdown. **Requires** a `values` array; a non-empty
  `default` must be one of the listed values (e.g. `proxy_protocol` in
  `direct.uc`, `multiplex_protocol` in `_shared/multiplex.uc`).
- `list` — UCI list option (rendered as a dynamic list). May carry `values` as
  combobox suggestions (e.g. `tls_alpn`).

`values` is therefore overloaded: a **strict whitelist** for `enum`, and
**combobox suggestions** (free entry retained) for `string`/`list`.

## Field hint vocabulary

- `tab: "<name>"` — **required**. Which modal tab the field renders in (`basic`,
  `credentials`, `tls`, `transport`, `multiplex`, `dial`, `advanced`, …).
- `required: true` — UI validates non-empty.
- `default: <value>` — value emitted / shown when the section field is null.
- `secret: true` — UI shows masked input; RPC output is scrubbed via
  `lib/scrub.uc`.
- `validate: "host"|"port"|"path"` — hint for the JS validators.
- `advanced: true` — hidden behind the per-tab “Show advanced fields” toggle.
  The registry auto-injects a virtual `_show_advanced_<tab>` bool per tab that
  has any advanced field.
- `placeholder: "<text>"` — input placeholder (e.g. `dial.uc` bind/timeout
  fields).
- `depends: { field, value }` — show only when another field equals `value`
  (`value` may be a string or an array).
- `dynamic: "<source>"` — a selector whose choices are populated at render time
  from live UCI / network state, **not** from a static `values` array. Known
  sources (`KNOWN_DYNAMIC` in `registry.uc`): `outbounds` (outbound tags),
  `dns_servers` (dns_server tags), `interfaces` (logical wan/lan interfaces, for
  `bind_interface`), `devices` (netdev names, for the tproxy `interface` field).
  Rendered by `descriptor_form.js::attachDynamic`. An unknown source is rejected
  by `register()`.
- `virtual: true` — a pure-UI toggle whose value is **not** persisted to UCI
  (write/remove are no-ops, `cfgvalue` returns the default). Used for the
  injected `_show_advanced_*` flags. Do **not** mark a field `virtual` if it is
  really read back from UCI by the backend — “not emitted to JSON” is achieved
  by `emit()` simply not referencing the field, not by `virtual`.

## Module resolution

`require("builder.protocols.registry")` and `require("builder.protocols.trojan")` use ucode's
dotted module syntax. The interpreter's `-L /usr/share/singbox-ui/lib` search
path (baked into every handler shebang as
`#!/usr/bin/ucode -L/usr/share/singbox-ui/lib`) resolves these to
`lib/builder/protocols/registry.uc` and `lib/builder/protocols/trojan.uc` respectively. No
additional `-L` flags are needed at any invocation site.

## Frontend projection

The descriptor metadata is projected to the frontend by
`lib/builder/protocols/schema_dump.uc` (exposed via the `protocol_schema` RPC, read
ACL). `emit` functions are dropped; only the declarative keys in its
`FIELD_WHITELIST` reach the UI — so a new field hint (e.g. `dynamic`) must be
added to that whitelist or it will be silently stripped before render. The JS
side renders the projection via `htdocs/.../lib/descriptor_form.js`.

## Tests

- `tests/backend/test_descriptor_materialize.test.ts` — descriptor registration +
  `materialize()` (shared-block merge, advanced-flag injection).
- `tests/backend/test_descriptor_resilience.test.ts` — a broken descriptor is logged and
  skipped (`try_register`) instead of aborting the eager-require chain.
- `tests/backend/test_registry_robustness.test.ts` — strict `register()` validation
  (enum↔values↔default, list/string+values, unknown `dynamic` source rejected).
- `tests/backend/test_protocol_schema_rpc.test.ts` — the `protocol_schema` RPC projection
  (including `dynamic` surviving the projection).
- `tests/ui/test_descriptor_form_dynamic_js.test.ts` — frontend dynamic-selector wiring
  (node).
