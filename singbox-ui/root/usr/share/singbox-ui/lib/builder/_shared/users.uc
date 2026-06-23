// lib/protocols/_shared/users.uc — universal declarative users[] builder.
// Subsumes inbound.uc build_user / build_inbound_users and per-protocol
// colon-split parsing. Driven by a descriptor `users` spec:
//   { from?: "<list_field>",
//     columns: [ { key, required?, always?, guard?:"uuid",
//                  validate?:[<allowed>], discard?, warn_if_empty? }, ... ],
//     single_fallback?: { fields: [ { key, from } ] },
//     clear_on_multi?: [ "<json_key>", ... ] }   // consumed by the filler
// Returns { users: [ {..}, .. ], from_list: bool }.
let helpers = require("helpers");
const s_opt    = helpers.s_opt;
const as_array = helpers.as_array;

// _split(entry, ncols) — split on the FIRST ncols-1 separators; the final
// column keeps the remainder verbatim (so a ':' inside the trailing secret is
// preserved). Returns an array of up to ncols parts.
function _split(entry, ncols) {
    let parts = [];
    let rest = entry;
    for (let i = 0; i < ncols - 1; i++) {
        let c = index(rest, ":");
        if (c < 0) { push(parts, rest); rest = null; break; }
        push(parts, substr(rest, 0, c));
        rest = substr(rest, c + 1);
    }
    if (rest != null) push(parts, rest);
    return parts;
}

function _parse_row(entry, spec) {
    let cols = spec.columns;
    let parts = _split(entry, length(cols));
    // Legacy invariant: every list parser requires the FIRST separator
    // (index(entry,":") < 0 => drop). A colon-less single token is never a
    // valid multi-column row.
    let nparts = length(parts);
    let ncols  = length(cols);
    if (ncols >= 2 && nparts < 2) return null;
    // If fewer parts than columns, check whether the missing trailing columns
    // are all optional (no required, no warn_if_empty). If any missing column
    // is required/warn_if_empty, skip the row (shape mismatch).
    if (nparts < ncols) {
        for (let i = nparts; i < ncols; i++) {
            if (cols[i].required || cols[i].warn_if_empty) return null;
        }
    }
    let u = {};
    for (let i = 0; i < ncols; i++) {
        let col = cols[i];
        let val = (i < nparts) ? parts[i] : "";
        if (col.required && !length(val)) return null;
        if (col.guard === "uuid" && !match(val, /^[0-9A-Za-z-]+$/)) {
            warn(sprintf("users.uc: row '%s' has malformed uuid '%s'; skipping\n", entry, val));
            return null;
        }
        if (col.validate != null && !(val in col.validate)) {
            warn(sprintf("users.uc: row '%s' has unknown %s '%s'; skipping\n", entry, col.key, val));
            return null;
        }
        if (col.warn_if_empty && !length(val)) {
            warn(sprintf("users.uc: row '%s' has empty %s; skipping\n", entry, col.key));
            return null;
        }
        if (col.discard) continue;
        if (col.always || length(val)) u[col.key] = val;
    }
    return u;
}

function _build_single(s, fb) {
    let u = { name: s[".name"] };
    let have_cred = false;
    for (let f in (fb.fields || []))
        if (length(s_opt(s, f.from))) { u[f.key] = s[f.from]; have_cred = true; }
    // Drop a credential-less fallback: a single-user section whose source
    // field(s) are all empty would otherwise emit users:[{name}] with no
    // password/uuid, which sing-box rejects. Returning null lets build() emit
    // no users[], so the missing credential surfaces as a clear error rather
    // than a malformed user object (BLD-5).
    if (!have_cred) return null;
    return u;
}

function build(s, spec) {
    let users = [];
    let from_list = false;
    if (spec.from != null) {
        for (let entry in as_array(s[spec.from])) {
            let u = _parse_row(entry, spec);
            if (u != null) push(users, u);
        }
        if (length(users)) from_list = true;
    }
    if (!length(users) && spec.single_fallback != null) {
        let u = _build_single(s, spec.single_fallback);
        if (u != null) push(users, u);
    }
    return { users: users, from_list: from_list };
}

return { build };
