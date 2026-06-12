// lib/protocols/_filler.uc — declarative field->JSON filler for protocol
// descriptors. Folds the mechanical rename/coerce/omit-if-empty path out of
// each descriptor's emit() into fields[] metadata, and auto-invokes declared
// shared blocks. emit()/post() remain an escape-hatch for nesting/conditionals
// (see protocols/registry.uc and outbound.uc build_constructor_for).

let helpers    = require("helpers");
let dial_blk   = require("protocols._shared.dial");
let users_blk  = require("protocols._shared.users");

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

// _gate(s, gate, opts) — evaluate a gate object. null gate => true.
function _gate(s, gate, opts) {
    if (gate == null) return true;
    if (gate.flag != null) return s_bool(s, gate.flag);
    if (gate.enabled_field != null)
        return s_bool(s, gate.enabled_field) || (opts != null && gate.force_opt != null && opts[gate.force_opt]);
    if (gate.all_present != null) {
        for (let n in gate.all_present) if (!length(s_opt(s, n))) return false;
        return length(gate.all_present) > 0;
    }
    if (gate.any_present != null) {
        for (let n in gate.any_present) if (length(s_opt(s, n))) return true;
        return false;
    }
    return true;
}

// _emit_seq / _emit_group are mutually recursive (a group's fields may contain
// nested groups). ucode does NOT hoist `function` declarations, so a forward
// reference would be a dangling name at definition time — forward-declare both
// with `let` and assign function expressions so each can see the other.
let _emit_seq, _emit_group;

// _emit_seq(out, s, seq) — walk a sequence of entries (scalar | const | group).
_emit_seq = function(out, s, seq) {
    for (let e in (seq || [])) {
        if ("const" in e) { out[e.json_key] = e.const; continue; }
        if (e.fields != null) { _emit_group(out, s, e); continue; }   // nested group
        if (e.json_key != null) { _emit_scalar(out, s, e); continue; }
    }
};

// _emit_group(out, s, g) — gated nested object built from g.fields.
_emit_group = function(out, s, g) {
    if (!_gate(s, g.gate, null)) return;
    let sub = {};
    _emit_seq(sub, s, g.fields);
    out[g.json_key] = sub;
};

// _build_block(s, spec, kind, opts) — build a shared-block object from its
// declarative emit_spec. Returns the object, or null when gated out.
//   spec: { gate?, merge?, variant?, outbound?:[seq], inbound?:[seq], seq?:[seq] }
function _build_block(s, spec, kind, opts) {
    if (spec.variant != null) {
        let v = spec.variant;
        let sel = s_opt(s, v.selector);
        if (!length(sel) || sel === v.none_value) return null;
        let entries = v.variants[sel];
        if (entries == null) return null;
        let obj = {};
        obj[v.emit_selector_as] = sel;
        _emit_seq(obj, s, entries);
        return obj;
    }
    if (!_gate(s, spec.gate, opts)) return (spec.merge ? {} : null);
    let obj = {};
    _emit_seq(obj, s, spec[kind] != null ? spec[kind] : spec.seq);
    return obj;
}

// _emit_shared(out, s, kind, d) — auto-invoke each declared shared block.
// Prefers a declarative emit_spec on the module; falls back to legacy fn/merge.
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
        let opts = (type(d.shared[blk]) === "object") ? d.shared[blk] : {};

        if (mod.emit_spec != null) {                 // declarative path
            if (spec.merge != null) {
                let o = _build_block(s, mod.emit_spec, kind, opts);
                for (let k in keys(o)) out[k] = o[k];
            } else {
                let res = _build_block(s, mod.emit_spec, kind, opts);
                if (res != null) out[spec.key] = res;
            }
            continue;
        }
        if (spec.merge != null) { mod[spec.merge](out, s); continue; }   // legacy
        let res = mod[spec.fn[kind]](s, opts);
        if (res != null) out[spec.key] = res;
    }
}

// build(d, s) — construct the sing-box JSON object for descriptor d from
// section s. Order: type/tag (or inbound base), declared fields (declaration
// order), declared groups (declaration order), declared shared blocks
// (declaration order), then optional post() escape-hatch.
function build(d, s) {
    let out;
    if (d.kind === "inbound") {
        out = dial_blk.build_listen_base(s, d.sing_box_type);
        if (out == null) return null;
    } else {
        out = { type: d.sing_box_type, tag: s[".name"] };
    }
    for (let f in (d.fields || [])) {
        if (f.json_key == null) continue;   // UI-only field
        _emit_scalar(out, s, f);
    }
    for (let g in (d.groups || [])) _emit_group(out, s, g);
    if (d.users != null) {
        let r = users_blk.build(s, d.users);
        if (length(r.users)) {
            out.users = r.users;
            if (r.from_list && d.users.clear_on_multi != null)
                for (let k in d.users.clear_on_multi) delete out[k];
        }
    }
    _emit_shared(out, s, d.kind, d);
    if (type(d.post) === "function") d.post(out, s);
    return out;
}

return { build };
