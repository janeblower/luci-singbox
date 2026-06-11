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
}

function validate_shared(shared, ctx) {
    if (shared == null) return;
    for (let k in shared)
        assert(KNOWN_SHARED[k] != null, sprintf("%s: unknown shared key '%s'", ctx, k));
}

function register(descriptor) {
    assert(descriptor.kind != null,            "descriptor.kind required");
    assert(descriptor.kind === "inbound" || descriptor.kind === "outbound",
        "descriptor.kind must be 'inbound' or 'outbound'");
    assert(descriptor.type != null,            "descriptor.type required");
    assert(type(descriptor.emit) === "function", "descriptor.emit must be a function");
    let ctx = sprintf("%s:%s", descriptor.kind, descriptor.type);
    validate_shared(descriptor.shared, ctx);
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
    try { return require(sprintf("protocols._shared.%s", name)); }
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
