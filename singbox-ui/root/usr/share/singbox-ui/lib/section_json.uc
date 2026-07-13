// lib/section_json.uc — the JSON <-> UCI-section bridge behind the JSON editor
// and the Export JSON buttons.
//
//   export_one(cur, kind, name)      -> { status:"ok", section }      | { status:"error", message }
//   import_one(cur, kind, name, obj) -> { status:"ok", tag, fields, known, extra }
//                                     | { status:"error", message }
//
// import_one is a PURE READ: it parses the JSON against the section's descriptor
// and hands the caller what to write. Nothing touches UCI here — the frontend
// applies the result into LuCI's own changeset, so Save & Apply (and Revert) work
// exactly as they do for a hand-edited form. That is also why the rpcd method is
// on the READ ACL.
//
// Six kinds, one table. `reg_kind` is the descriptor registry's name for the
// kind, which is not always the UCI section type (`ruleset` -> `rule_set`,
// `dns_server` -> `dns`).
//
// A caveat worth knowing: for route_rule / dns_rule / ruleset the exported object
// is the DESCRIPTOR-level JSON, not the final config fragment. Those three are
// post-processed across sections at generate time (rule-set refs are resolved,
// logical sub-rules are inlined, a rule-set's `format` is sniffed from its URL
// and `update_interval` is re-spelled as "<n>s"), and none of that is a property
// of the section on its own. Exporting the post-processed form would hand back
// keys the importer cannot map to any UCI option, which would then round-trip
// into json_extra and be emitted twice.

let filler   = require("builder._filler");
let unfiller = require("builder._unfiller");

const KINDS = {
    inbound:    { reg: "builder.protocols.registry", reg_kind: "inbound",    discr: "protocol", def: null },
    outbound:   { reg: "builder.protocols.registry", reg_kind: "outbound",   discr: "type",     def: null },
    dns_server: { reg: "builder.dns.registry",       reg_kind: "dns",        discr: "type",     def: null },
    dns_rule:   { reg: "builder.dns_rule.registry",  reg_kind: "dns_rule",   discr: "type",     def: "default" },
    route_rule: { reg: "builder.route.registry",     reg_kind: "route_rule", discr: "type",     def: "default" },
    ruleset:    { reg: "builder.route.registry",     reg_kind: "rule_set",   discr: "type",     def: "remote" },
};

// The UI-only outbound shapes. They are not built from a descriptor at all — a
// subscription is a URL that is fetched and expanded into many outbounds, and a
// share-link is parsed at generate time — so there is no single JSON object that
// round-trips, and the UI greys their Export button out.
const NO_JSON_OUTBOUND = { subscription: 1, url: 1, interface: 1 };

function err(msg) { return { status: "error", message: msg }; }

// _resolve(cur, kind, name) -> { d, section, type } | { error }
// Loads the right registry (requiring `inbound`/`outbound` first: they eagerly
// pull in every protocol descriptor, including the plugin ones, so the registry
// is only populated afterwards).
function _resolve(cur, kind, name) {
    let k = KINDS[kind];
    if (k == null) return { error: "invalid kind: " + (length(kind) ? kind : "<missing>") };

    let section = cur.get_all("singbox-ui", name);
    if (!section)                      return { error: "section not found" };
    if (section[".type"] !== kind)     return { error: sprintf("section is not %s", kind) };

    let t = section[k.discr] ?? "";
    if (!length(t) && k.def != null) t = k.def;
    if (!length(t))                    return { error: "section has no " + k.discr };
    if (kind === "outbound" && NO_JSON_OUTBOUND[t])
        return { error: "does not support type=" + t };

    // Eager-load. protocols/registry only knows a descriptor once the module that
    // registers it has been required.
    try {
        if (kind === "inbound")       require("inbound");
        else if (kind === "outbound") require("outbound");
    } catch (e) { return { error: sprintf("require(%s) failed", kind) }; }

    let reg;
    try { reg = require(k.reg); } catch (e) { return { error: "require(" + k.reg + ") failed" }; }

    let d = reg.get(k.reg_kind, t);
    if (d == null) return { error: sprintf("unknown %s type: %s", kind, t) };

    return { d: d, section: section, type: t };
}

function export_one(cur, kind, name) {
    let r = _resolve(cur, kind, name);
    if (r.error) return err(r.error);

    // A descriptor may still carry the legacy emit() escape hatch (the awg_warp
    // plugin does). It builds fine, but _unfiller cannot invert code — so such a
    // section exports read-only and the editor refuses it (see import_one).
    let obj = (type(r.d.emit) === "function") ? r.d.emit(r.section)
                                             : filler.build(r.d, r.section);
    if (obj == null) return err("builder returned null");
    return { status: "ok", section: obj };
}

function import_one(cur, kind, name, obj) {
    if (type(obj) !== "object" || type(obj) === "array")
        return err("expected a JSON object");

    let r = _resolve(cur, kind, name);
    if (r.error) return err(r.error);

    // No inverse exists for a hand-written emit(): the mapping lives in code, not
    // in the spec. Refusing beats silently writing a half-parsed section.
    if (type(r.d.emit) === "function")
        return err(sprintf("type=%s is built by custom code and cannot be imported from JSON", r.type));

    let p = unfiller.parse(r.d, obj);

    // `tag` is the UCI section name. A changed tag is a RENAME of this section —
    // never a new one — and the frontend rewrites the references along with it.
    // Headerless kinds (route_rule, dns_rule) carry no tag at all.
    let tag = (type(obj.tag) === "string" && length(obj.tag)) ? obj.tag : null;

    return {
        status: "ok",
        tag:    tag,
        fields: p.fields,
        known:  keys(p.known),
        extra:  p.extra,
    };
}

return { export_one, import_one, KINDS, NO_JSON_OUTBOUND };
