// lib/builder/_unfiller.uc — the inverse of _filler.uc.
//
// parse(d, json) walks the SAME declarative tree _filler.build() walks
// (fields → groups → users → shared blocks, via the same SHARED_DISPATCH) but
// reads out[json_key] into fields[name] instead of writing it. It powers the
// JSON editor: export a section, hand the user the sing-box JSON, and turn what
// they hand back into UCI values.
//
// Returns { fields, extra, known }:
//   fields — { <uci option name>: <string | array of strings> } for the keys the
//            JSON actually carried.
//   extra  — every json key the descriptor tree did NOT consume, nested exactly
//            as it appeared. The caller stores it verbatim in `json_extra`,
//            which _filler.build() deep-merges back into the built object. So a
//            key this file cannot express is preserved rather than silently
//            dropped — but the user is asked about it first (the frontend shows
//            them the list before saving).
//   known  — every UCI option this descriptor COULD produce, present in the JSON
//            or not. That is what lets the caller apply a DIFF: a known field the
//            new JSON no longer carries gets removed, while a UCI-only field
//            (enabled, builtin, nft_rules, sub_*) — which has no json_key and is
//            therefore never in `known` — is left alone.
//
//            This is also why an absent bool is NOT written back as "0": it is in
//            `known`, so the caller removes it, and an absent UCI option is
//            already false. Writing "0" for every unset flag would bury the real
//            settings under twenty `*_enabled '0'` lines.
//
// The one thing it deliberately does NOT invert is a `users` spec with a
// `discard` column: shadowsocks stores `method` in the UCI row for validation
// and does not emit it, so the JSON simply has nothing to rebuild the row from.
// Such a `users` array falls through to `extra` and is re-emitted verbatim —
// which round-trips byte-identically, it just cannot be re-derived.
//
// post() is NOT inverted either, and does not need to be: the three descriptors
// that use it (clash_api, dns/legacy, shadowsocks) only reshape or delete keys
// the spec already describes; none of them invents one.

let helpers = require("helpers");

const SHARED_DISPATCH = {
    tls:       { key: "tls" },
    transport: { key: "transport" },
    multiplex: { key: "multiplex" },
    quic:      { merge: true },
    dial:      { merge: true },
    listen:    { merge: true },
};

// _gated(e) — the mirror of _filler._emit_scalar's min_version check: an entry the
// running core is too old for is one _filler will NOT emit, so this file must not
// claim it either. It is skipped in BOTH walks, and that pairing is the point:
//
//   * out of `known`  => the diff-apply rule ("known, but absent from the JSON =>
//     delete from UCI") can no longer wipe a value that was set on a newer core
//     and is merely invisible on this one. Silent data loss, otherwise.
//   * out of `parse`  => the same key ARRIVING in pasted JSON is not consumed, so
//     it lands in `extra` -> json_extra -> re-emitted verbatim. That is the right
//     trade: the user's data survives, and if they really did paste a 1.14 key
//     onto a 1.12 core the failure is LOUD (init.d's `sing-box check` refuses the
//     start and says which field) instead of the value quietly vanishing.
function _gated(e) {
    return e.min_version != null && !helpers.core_at_least(e.min_version);
}

// _uncoerce(f, v) — JSON value -> UCI value. Mirrors _filler._emit_scalar's
// coerce switch. UCI has no types: everything is a string, and a list is an
// array of strings.
function _uncoerce(f, v) {
    let coerce = f.coerce ?? "str";
    if (coerce === "bool") return v ? "1" : "0";
    if (coerce === "array" || coerce === "num_array") {
        let a = (type(v) === "array") ? v : [ v ];
        let out = [];
        for (let x in a) push(out, "" + x);
        return out;
    }
    if (coerce === "duration") {
        // "86400s" -> "86400". UCI stores plain seconds; the filler spells it as a
        // sing-box duration. A value we cannot read (a unit other than seconds, or
        // junk) is passed through verbatim rather than silently zeroed — the form
        // will then reject it, which is louder than losing it.
        let m = match("" + v, /^([0-9]+)s?$/);
        return m ? m[1] : ("" + v);
    }
    return "" + v;
}

// _parse_seq(fields, obj, seq, seen, extra) — walk one sequence of entries
// (scalar | const | group), filling `fields` from `obj`.
//
// `seen` collects every json key of `obj` the sequence claimed, so the CALLER
// can work out what was left over. It is deliberately not computed here: a
// `merge` shared block (dial, quic) runs over the WHOLE top-level object, and a
// leftover scan inside would report every unrelated sibling key as unknown.
//
// A nested group's leftovers ARE collected here, under the group's json_key,
// because only this frame knows where they came from.
function _parse_seq(fields, obj, seq, seen, extra) {
    for (let e in (seq ?? [])) {
        if (_gated(e)) continue;                      // not emittable here -> not ours
        // A const is emitted by the builder, never stored — consume, don't map.
        if ("const" in e) { seen[e.json_key] = true; continue; }

        if (e.fields != null) {                       // nested group
            seen[e.json_key] = true;
            let sub = obj[e.json_key];
            if (type(sub) !== "object") continue;
            // The presence of the nested object IS the gate. `all_present` /
            // `any_present` gates are derived from the member fields, so there is
            // nothing to set for those — only an explicit flag needs writing.
            if (e.gate != null && e.gate.flag != null) fields[e.gate.flag] = "1";
            let sseen = {}, sextra = {};
            _parse_seq(fields, sub, e.fields, sseen, sextra);
            let left = {};
            for (let k in sub)    if (!sseen[k]) left[k] = sub[k];
            for (let k in sextra) left[k] = sextra[k];
            if (length(keys(left))) extra[e.json_key] = left;
            continue;
        }

        if (e.json_key == null) continue;             // UI-only field
        seen[e.json_key] = true;
        let v = obj[e.json_key];
        if (v == null || e.name == null) continue;    // absent -> caller removes it
        fields[e.name] = _uncoerce(e, v);
    }
}

// _seq_names(known, seq) — the name half of _parse_seq: every UCI option this
// sequence can reach, whether or not the JSON at hand carries it.
function _seq_names(known, seq) {
    for (let e in (seq ?? [])) {
        if (_gated(e)) continue;                      // see _gated() above
        if ("const" in e) continue;
        if (e.fields != null) {
            if (e.gate != null && e.gate.flag != null) known[e.gate.flag] = true;
            _seq_names(known, e.fields);
            continue;
        }
        if (e.json_key != null && e.name != null) known[e.name] = true;
    }
}

// _users_list_invertible(spec) — can the ':'-separated UCI list be rebuilt from
// the JSON? Not if any column is `discard`ed: shadowsocks keeps `method` in the
// row for validation and never emits it, so the JSON has nothing to rebuild it
// from. (Defined above its callers: ucode resolves top-level functions in order.)
function _users_list_invertible(spec) {
    if (spec == null || spec.from == null) return false;
    for (let col in spec.columns) if (col.discard) return false;
    return true;
}

// _parse_users(fields, json, spec) -> bool (consumed?)
// The inverse of users.build(). Two shapes:
//   * a list spec (`from`) — re-join each user object into its UCI row;
//   * a single_fallback-only spec (trojan: the credential lives in a plain field,
//     there is no per-user list at all) — map the one user back to those fields.
// Anything else (a discard column, several users against a single_fallback) is
// left to `extra`, where it round-trips verbatim instead of being half-written.
function _parse_users(fields, json, spec) {
    let us = json.users;
    if (type(us) !== "array") {
        // The spec owns the key even when the JSON has no users at all — the
        // caller then removes the fields, which is how you delete a credential.
        return _users_list_invertible(spec) || spec.single_fallback != null;
    }

    if (_users_list_invertible(spec)) {
        let rows = [];
        for (let u in us) {
            let parts = [];
            for (let col in spec.columns) push(parts, "" + (u[col.key] ?? ""));
            push(rows, join(":", parts));
        }
        fields[spec.from] = rows;
        return true;
    }

    if (spec.single_fallback != null && length(us) === 1) {
        for (let f in (spec.single_fallback.fields ?? [])) {
            let v = us[0][f.key];
            if (v != null) fields[f.from] = "" + v;
        }
        return true;
    }
    return false;
}

// _parse_shared(fields, json, kind, d, seen, extra) — invert each declared
// shared block through its own emit_spec, exactly as _filler._emit_shared builds
// it.
function _parse_shared(fields, json, kind, d, seen, extra) {
    if (d.shared == null) return;
    for (let blk in d.shared) {
        let disp = SHARED_DISPATCH[blk];
        if (disp == null) continue;
        let mod;
        try { mod = require(sprintf("builder._shared.%s", blk)); }
        catch (e) { continue; }
        if (mod == null || mod.emit_spec == null) continue;
        let spec = mod.emit_spec;

        // transport: a tagged union. `type` picks the variant; the rest of the
        // object is that variant's sequence.
        if (spec.variant != null) {
            let v = spec.variant;
            seen[disp.key] = true;
            let sub = json[disp.key];
            // Absent: write nothing. The selector is in `known`, so the caller
            // removes it, and an unset selector is exactly what "no transport"
            // means to the filler. Same rule everywhere: absent in JSON => removed.
            if (type(sub) !== "object") continue;
            let sel = sub[v.emit_selector_as];
            fields[v.selector] = "" + (sel ?? v.none_value);
            let entries = v.variants[sel];
            if (entries == null) { extra[disp.key] = sub; continue; }   // transport we don't model
            let sseen = {}, sextra = {};
            sseen[v.emit_selector_as] = true;   // the discriminator itself
            _parse_seq(fields, sub, entries, sseen, sextra);
            let left = {};
            for (let k in sub)    if (!sseen[k]) left[k] = sub[k];
            for (let k in sextra) left[k] = sextra[k];
            if (length(keys(left))) extra[disp.key] = left;
            continue;
        }

        // merge blocks (dial, quic) live at the TOP level of the object.
        if (disp.merge) {
            _parse_seq(fields, json, spec.seq, seen, extra);
            continue;
        }

        // keyed blocks (tls, multiplex): the nested object's presence is the gate.
        seen[disp.key] = true;
        let sub = json[disp.key];
        let gate = spec.gate;
        if (type(sub) !== "object") continue;   // absent -> caller removes the flag
        if (gate != null && gate.enabled_field != null) fields[gate.enabled_field] = "1";
        // tls is direction-keyed (a dns server is a TLS *client*, so it reads the
        // outbound sequence) — same resolution _filler._build_block does.
        let seq = spec[kind] != null ? spec[kind]
                  : (spec.seq != null ? spec.seq
                     : (kind === "inbound" ? spec.inbound : spec.outbound));
        let sseen = {}, sextra = {};
        _parse_seq(fields, sub, seq, sseen, sextra);
        let left = {};
        for (let k in sub)    if (!sseen[k]) left[k] = sub[k];
        for (let k in sextra) left[k] = sextra[k];
        if (length(keys(left))) extra[disp.key] = left;
    }
}

// field_names(d) — every UCI option descriptor `d` can produce. The caller diffs
// against this: a name in here but not in `fields` is removed; a name not in here
// is UCI-only and never touched.
function field_names(d) {
    let known = {};
    // Mirrors _filler.build()'s discriminator exactly: build_listen_base (and
    // thus listen/listen_port) only exists for a descriptor that DECLARES
    // shared:{listen:true} — tun is kind:"inbound" but not a listener, and has no
    // listen_port field to own.
    if (d.kind === "inbound" && d.shared != null && d.shared.listen) {
        known.listen = true; known.listen_port = true;
    }
    for (let f in (d.fields ?? [])) if (f.json_key != null && !_gated(f)) known[f.name] = true;
    _seq_names(known, d.groups ?? []);
    if (d.users != null) {
        if (_users_list_invertible(d.users)) known[d.users.from] = true;
        // The single_fallback fields too, and for BOTH shapes: deleting users[]
        // from the JSON has to actually delete the credential, wherever it lives.
        // A descriptor with both (hysteria2) parses into the list, so its plain
        // field must be cleared or build() would resurrect the user from it.
        for (let f in ((d.users.single_fallback ?? {}).fields ?? [])) known[f.from] = true;
    }

    if (d.shared != null) for (let blk in d.shared) {
        let disp = SHARED_DISPATCH[blk];
        if (disp == null) continue;
        let mod;
        try { mod = require(sprintf("builder._shared.%s", blk)); }
        catch (e) { continue; }
        if (mod == null || mod.emit_spec == null) continue;
        let spec = mod.emit_spec;
        if (spec.variant != null) {
            known[spec.variant.selector] = true;
            // EVERY variant, not just the selected one: switching a transport from
            // grpc to ws has to clear the grpc-only fields, so they must be known.
            for (let vn, entries in spec.variant.variants) _seq_names(known, entries);
            continue;
        }
        if (spec.gate != null) {
            if (spec.gate.enabled_field != null) known[spec.gate.enabled_field] = true;
            if (spec.gate.flag != null)          known[spec.gate.flag] = true;
        }
        // Both directions: tls declares separate inbound/outbound sequences, and a
        // field belonging to the other side must still be clearable if it somehow
        // ended up set.
        _seq_names(known, spec.seq);
        _seq_names(known, spec.inbound);
        _seq_names(known, spec.outbound);
    }
    return known;
}

// parse(d, json) -> { fields, extra, known }
function parse(d, json) {
    if (type(json) !== "object") return { fields: {}, extra: {}, known: field_names(d) };
    let kind = d.kind;
    let fields = {};
    let seen = {};
    let extra = {};

    // Header. `type` is the discriminator (the caller already knows it) and `tag`
    // is the UCI section name — the caller turns a changed tag into a rename, not
    // into a field. HEADERLESS descriptors carry neither.
    const HEADERLESS = { route_rule: 1, dns_rule: 1, cache: 1, clash_api: 1 };
    if (!HEADERLESS[kind]) { seen.type = true; seen.tag = true; }

    // `derived_keys` are keys the builder COMPUTES rather than reads (a rule-set's
    // `format` is sniffed from its url/path extension, and is not a UCI option at
    // all). They must be consumed, or the editor would report them as unknown and
    // stash them in json_extra — where the next build would then emit them twice.
    for (let k in (d.derived_keys ?? [])) seen[k] = true;
    if (kind === "inbound" && d.shared != null && d.shared.listen) {
        // build_listen_base owns these two — they have no json_key of their own.
        // Same discriminator as _filler.build() / field_names() above: a
        // non-listener inbound (tun) declares no shared.listen, so a pasted
        // listen_port has nothing to consume it and falls through to `extra`
        // instead of resurrecting a dead UCI option.
        seen.listen = true;
        seen.listen_port = true;
        if (json.listen != null)      fields.listen      = "" + json.listen;
        if (json.listen_port != null) fields.listen_port = "" + json.listen_port;
    }

    for (let f in (d.fields ?? [])) {
        if (f.json_key == null || _gated(f)) continue;   // UI-only, or not emittable here
        seen[f.json_key] = true;
        let v = json[f.json_key];
        if (v == null) continue;                      // absent -> caller removes it
        fields[f.name] = _uncoerce(f, v);
    }

    // A declared group has the same shape as a group entry inside a sequence.
    _parse_seq(fields, json, d.groups ?? [], seen, extra);

    if (d.users != null && _parse_users(fields, json, d.users)) seen.users = true;

    _parse_shared(fields, json, kind, d, seen, extra);

    let leftover = {};
    for (let k in json)  if (!seen[k]) leftover[k] = json[k];
    for (let k in extra) leftover[k] = extra[k];

    return { fields: fields, extra: leftover, known: field_names(d) };
}

return { parse, field_names };
