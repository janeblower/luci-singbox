// lib/protocols/registry.uc — protocol descriptor registry (Phase E2 DSL).
//
// Descriptor shape:
//   {
//     kind:          "outbound" | "inbound",
//     type:          <UCI type tag>,
//     sing_box_type: <string>,
//     shared:        { tls?: {...}, transport?: {...}, multiplex?: {...}, dial?: true },
//     fields:        [{ name, type, tab, required?, default?, validate?, secret?,
//                       advanced?, depends?: {field,value}, parent_enabled?,
//                       placeholder?, values?, item?, virtual? }, ...],
//     emit:          function(section) -> sing-box JSON object,
//   }
//
// materialize(kind, type) returns the descriptor with shared-block fields
// merged in and per-tab _show_advanced_<tab> flags auto-injected.

let _registry = {};
let _materialize_cache = {};

const KNOWN_SHARED  = { tls: 1, transport: 1, multiplex: 1, dial: 1 };
const KNOWN_TYPES   = { string: 1, number: 1, bool: 1, enum: 1, list: 1 };
// `dynamic` marks a selector whose choices are populated at render time from
// live UCI / network state (see descriptor_form.js attachDynamic), not from a
// static `values` array.
const KNOWN_DYNAMIC = { outbounds: 1, dns_servers: 1, interfaces: 1, devices: 1 };
const KNOWN_COERCE  = { str: 1, num: 1, bool: 1, array: 1 };
const KNOWN_OMIT    = { empty: 1, never: 1 };

function validate_field(f, ctx) {
    assert(f.name != null,                        sprintf("%s: field.name required", ctx));
    assert(KNOWN_TYPES[f.type] != null,           sprintf("%s: field.type unknown: %s", ctx, f.type));
    // All descriptors use `tab` (E2 DSL). Legacy `group` fallback removed.
    assert(f.tab != null,                         sprintf("%s.%s: field.tab required", ctx, f.name));
    if (f.depends != null) {
        assert(f.depends.field != null,           sprintf("%s.%s: depends.field required", ctx, f.name));
        assert(f.depends.value != null,           sprintf("%s.%s: depends.value required (string or array)", ctx, f.name));
    }
    // enum <-> values <-> default consistency (S4-5). A `values` list is the
    // hallmark of an enum: it must be an enum and only an enum. A non-empty
    // default must be one of the listed values. This is the check that would
    // have caught the direct.proxy_protocol type=number+values bug.
    if (f.values != null) {
        assert(type(f.values) === "array",        sprintf("%s.%s: field.values must be an array", ctx, f.name));
        // `values` is a strict whitelist for enum and a datalist of combobox
        // suggestions for string/list (free entry retained). number/bool may
        // not carry values — this is the check that caught the
        // direct.proxy_protocol type=number+values bug (S4-5).
        assert(f.type === "enum" || f.type === "string" || f.type === "list",
               sprintf("%s.%s: field.values requires type enum|string|list (got '%s')", ctx, f.name, f.type));
    }
    if (f.dynamic != null)
        assert(KNOWN_DYNAMIC[f.dynamic] != null,
               sprintf("%s.%s: unknown dynamic source '%s'", ctx, f.name, f.dynamic));
    if (f.type === "enum")
        assert(type(f.values) === "array",        sprintf("%s.%s: enum field requires a values array", ctx, f.name));
    if (f.type === "enum" && f.default != null && f.default !== "") {
        let found = false;
        for (let v in f.values) if (v === f.default) found = true;
        assert(found,                             sprintf("%s.%s: default '%s' is not one of values", ctx, f.name, f.default));
    }
    if (f.json_key != null)
        assert(type(f.json_key) === "string" && length(f.json_key) > 0,
               sprintf("%s.%s: json_key must be a non-empty string", ctx, f.name));
    if (f.coerce != null)
        assert(KNOWN_COERCE[f.coerce] != null,
               sprintf("%s.%s: unknown coerce '%s'", ctx, f.name, f.coerce));
    if (f.omit_when != null)
        assert(KNOWN_OMIT[f.omit_when] != null,
               sprintf("%s.%s: unknown omit_when '%s'", ctx, f.name, f.omit_when));
    if (f.skip_value != null)
        assert(type(f.skip_value) === "string",
               sprintf("%s.%s: skip_value must be a string", ctx, f.name));
    if (f.only_values != null)
        assert(type(f.only_values) === "array",
               sprintf("%s.%s: only_values must be an array", ctx, f.name));
    if (f.requires != null)
        assert(type(f.requires) === "string" ||
               (type(f.requires) === "object" && f.requires.field != null && f.requires.value != null),
               sprintf("%s.%s: requires must be a string or {field,value}", ctx, f.name));
}

function validate_shared(shared, ctx) {
    if (shared == null) return;
    for (let k in shared)
        assert(KNOWN_SHARED[k] != null, sprintf("%s: unknown shared key '%s'", ctx, k));
}

function _validate_seq(seq, ctx) {
    for (let e in (seq || [])) {
        if ("const" in e) { assert(e.json_key != null, sprintf("%s: const entry needs json_key", ctx)); continue; }
        if (e.fields != null) { _validate_seq(e.fields, ctx); assert(e.json_key != null, sprintf("%s: group needs json_key", ctx)); continue; }
        assert(e.json_key != null && e.name != null, sprintf("%s: scalar entry needs name+json_key", ctx));
    }
}
function validate_groups(groups, ctx) {
    if (groups == null) return;
    for (let g in groups) {
        assert(g.json_key != null, sprintf("%s: group needs json_key", ctx));
        _validate_seq(g.fields, ctx);
    }
}
function validate_users(u, ctx) {
    if (u == null) return;
    assert(type(u.columns) === "array" || u.single_fallback != null,
           sprintf("%s: users needs columns[] or single_fallback", ctx));
}

function register(descriptor) {
    assert(descriptor.kind != null,            "descriptor.kind required");
    assert(descriptor.kind === "inbound" || descriptor.kind === "outbound" || descriptor.kind === "dns",
        "descriptor.kind must be 'inbound', 'outbound', or 'dns'");
    assert(descriptor.type != null,            "descriptor.type required");
    // A descriptor builds its JSON either via a hand-written emit() (legacy /
    // escape-hatch) or declaratively via fields[] consumed by builder._filler.
    // At least one must be present. post() is an optional filler escape-hatch.
    let _has_emit = type(descriptor.emit) === "function";
    // A declarative descriptor needs at least one field to build anything
    // meaningful; an empty fields[] + no emit would silently emit just
    // {type,tag} — reject it so the omission fails loudly at registration.
    let _has_decl = (type(descriptor.fields) === "array" && length(descriptor.fields) > 0)
                    || (type(descriptor.groups) === "array" && length(descriptor.groups) > 0)
                    || (descriptor.users != null);
    assert(_has_emit || _has_decl,
        "descriptor must provide emit() or a non-empty declarative fields[]");
    if (descriptor.emit != null)
        assert(_has_emit, "descriptor.emit, when present, must be a function");
    if (descriptor.post != null)
        assert(type(descriptor.post) === "function", "descriptor.post must be a function");
    let ctx = sprintf("%s:%s", descriptor.kind, descriptor.type);
    validate_shared(descriptor.shared, ctx);
    validate_groups(descriptor.groups, ctx);
    validate_users(descriptor.users, ctx);
    for (let f in (descriptor.fields || []))
        validate_field(f, ctx);
    _registry[ctx] = descriptor;
    delete _materialize_cache[ctx];
}

// try_register(descriptor) — register() that never throws. A malformed
// descriptor (or shared block) is logged and skipped so one broken file
// cannot abort the eager-require chain in outbound.uc / inbound.uc and take
// down config generation. Built-in callers use register() (strict, unit-
// tested); the plugin/descriptor bring-up paths use try_register().
function try_register(descriptor) {
    try {
        register(descriptor);
        return true;
    } catch (e) {
        warn(sprintf("registry: skipping descriptor (%s:%s): %s\n",
            (descriptor != null ? descriptor.kind : "?"),
            (descriptor != null ? descriptor.type : "?"), e));
        return false;
    }
}

function get(kind, type_) {
    return _registry[sprintf("%s:%s", kind, type_)];
}

function types_for_kind(kind) {
    let out = [];
    for (let k in _registry)
        if (_registry[k].kind === kind) push(out, _registry[k].type);
    return out;
}

// _shared_module(name) — lazy loader that returns the corresponding
// _shared/<name>.uc module, or null if it does not exist. A genuine load
// error (syntax error, bad export) is logged via warn() before returning
// null — otherwise a broken shared module silently strips its fields from
// the materialized UI with no diagnostic (S4-4).
function _shared_module(name) {
    try { return require(sprintf("builder._shared.%s", name)); }
    catch (e) {
        warn(sprintf("registry: shared module '%s' failed to load: %s\n", name, e));
        return null;
    }
}

function _shared_fields(d) {
    let out = [];
    if (d.shared == null) return out;
    for (let blk in d.shared) {
        let mod = _shared_module(blk);
        if (mod == null) continue;
        let applies = mod.applies_to || { kinds: ["inbound", "outbound"] };
        let kinds_ok = false;
        for (let k in applies.kinds) if (k === d.kind) kinds_ok = true;
        if (!kinds_ok) continue;
        for (let f in (mod.fields || [])) push(out, f);
    }
    return out;
}

function _inject_advanced_flags(fields) {
    let tabs_with_advanced = {};
    for (let f in fields)
        if (f.advanced && f.tab != null) tabs_with_advanced[f.tab] = 1;
    let injected = [];
    for (let tab in tabs_with_advanced) {
        push(injected, {
            name: sprintf("_show_advanced_%s", tab),
            type: "bool", tab: tab, virtual: true, default: 0,
            ui_label: "Show advanced fields",
        });
    }
    // Prepend so the toggle renders first inside its tab.
    return [ ...injected, ...fields ];
}

function _tabs_for(fields) {
    let seen = {}, out = [];
    for (let f in fields) {
        if (seen[f.tab]) continue;
        seen[f.tab] = 1; push(out, f.tab);
    }
    return out;
}

function materialize(kind, type_) {
    let key = sprintf("%s:%s", kind, type_);
    if (_materialize_cache[key] != null) return _materialize_cache[key];
    let d = _registry[key];
    if (d == null) return null;
    let merged = [ ...(d.fields || []), ..._shared_fields(d) ];
    let with_adv = _inject_advanced_flags(merged);
    let result = {
        kind: d.kind,
        type: d.type,
        sing_box_type: d.sing_box_type,
        shared: d.shared || {},
        fields: with_adv,
        tabs: _tabs_for(with_adv),
    };
    _materialize_cache[key] = result;
    return result;
}

return { register, try_register, get, types_for_kind, materialize, _registry };
