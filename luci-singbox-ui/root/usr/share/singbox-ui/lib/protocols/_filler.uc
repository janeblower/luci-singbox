// lib/protocols/_filler.uc — declarative field->JSON filler for protocol
// descriptors. Folds the mechanical rename/coerce/omit-if-empty path out of
// each descriptor's emit() into fields[] metadata, and auto-invokes declared
// shared blocks. emit()/post() remain an escape-hatch for nesting/conditionals
// (see protocols/registry.uc and outbound.uc build_constructor_for).

let helpers = require("helpers");

const s_opt    = helpers.s_opt;
const s_num    = helpers.s_num;
const s_bool   = helpers.s_bool;
const as_array = helpers.as_array;

// Bridges the (intentionally inconsistent) shared-block export shapes to one
// uniform call. `key`-style blocks return an object merged under out[key];
// `merge`-style blocks mutate out in place. Shared modules are NOT modified.
const SHARED_DISPATCH = {
    tls:       { key: "tls",       fn: { outbound: "emit_outbound", inbound: "emit_inbound" } },
    transport: { key: "transport", fn: { outbound: "emit",          inbound: "emit" } },
    multiplex: { key: "multiplex", fn: { outbound: "emit",          inbound: "emit" } },
    dial:      { merge: "merge_dial" },
};

// _emit_scalar(out, s, f) — write one scalar field per its metadata:
// json_key / coerce / omit_when / skip_value / requires / default_when_empty.
// Fields without json_key never reach here (filtered in build()).
function _emit_scalar(out, s, f) {
    if (f.requires != null) {
        if (type(f.requires) === "string") {
            if (!length(s_opt(s, f.requires))) return;
        } else {
            if (s_opt(s, f.requires.field) !== f.requires.value) return;
        }
    }
    let coerce = f.coerce || "str";
    let omit   = f.omit_when || "empty";

    if (coerce === "bool") {
        // bool emits literal true when set, omits the key otherwise.
        if (s_bool(s, f.name)) out[f.json_key] = true;
        return;
    }
    if (coerce === "array") {
        // Mirror legacy emit() list handling exactly: as_array() wraps a scalar
        // and passes arrays through. UCI list fields arrive as arrays via
        // cur.foreach(), so this preserves byte-identical parity. (Do NOT add
        // string-splitting here — legacy emit never split, and divergence would
        // break the parity invariant for any future list-field conversion.)
        let a = as_array(s[f.name]);
        if (omit === "never" || length(a)) out[f.json_key] = a;
        return;
    }
    if (coerce === "num") {
        if (omit === "never" || length(s_opt(s, f.name)))
            out[f.json_key] = s_num(s[f.name]);
        return;
    }
    // "str" (default)
    let v = s_opt(s, f.name);
    if (f.skip_value != null && v === f.skip_value) return;
    if (!length(v) && f.default_when_empty != null) v = f.default_when_empty;
    if (omit === "never" || length(v)) out[f.json_key] = v;
}

// _emit_shared(out, s, kind, d) — auto-invoke each declared shared block.
function _emit_shared(out, s, kind, d) {
    if (d.shared == null) return;
    for (let blk in d.shared) {
        let spec = SHARED_DISPATCH[blk];
        if (spec == null) {
            warn(sprintf("_filler: unknown shared block '%s'; skipping\n", blk));
            continue;
        }
        let mod;
        try { mod = require(sprintf("protocols._shared.%s", blk)); }
        catch (e) { warn(sprintf("_filler: shared '%s' failed to load: %s\n", blk, e)); continue; }
        if (mod == null) continue;

        if (spec.merge != null) {
            mod[spec.merge](out, s);
            continue;
        }
        let opts = (type(d.shared[blk]) === "object") ? d.shared[blk] : {};
        let res = mod[spec.fn[kind]](s, opts);
        if (res != null) out[spec.key] = res;
    }
}

// build(d, s) — construct the sing-box JSON object for descriptor d from
// section s. Order: type/tag, declared fields (declaration order), declared
// shared blocks (declaration order), then optional post() escape-hatch.
function build(d, s) {
    let out = { type: d.sing_box_type, tag: s[".name"] };
    for (let f in (d.fields || [])) {
        if (f.json_key == null) continue;   // UI-only field
        _emit_scalar(out, s, f);
    }
    _emit_shared(out, s, d.kind, d);
    if (type(d.post) === "function") d.post(out, s);
    return out;
}

return { build };
