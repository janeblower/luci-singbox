// lib/ruleset.uc — sing-box route.rule_set definitions for referenced rule-sets.
// remote/local entries are built declaratively (url/path/download_detour via the
// descriptor + filler); format + update_interval are post-processed here
// (auto-detect / "<n>s"). inline entries embed headless rules built from the
// referenced default route_rule sections.

let helpers  = require("helpers");
let reg      = require("builder.route.registry");
let filler   = require("builder._filler");
let headless = require("builder.route.headless");

function detect_format(rs) {
    let src = (rs.type === "local") ? (rs.path ?? "") : (rs.url ?? "");
    return helpers.detect_rs_format(src, rs.format);
}

// build_rule_sets(cur, referenced_names) -> [{tag, type, ...}, ...]
function build_rule_sets(cur, referenced_names) {
    let rule_sets = [];
    let by_name = {};
    cur.foreach("singbox-ui", "ruleset", function(s) { by_name[s[".name"]] = s; });
    let rr_by_name = {};
    cur.foreach("singbox-ui", "route_rule", function(s) { rr_by_name[s[".name"]] = s; });

    for (let name in referenced_names) {
        let rs = by_name[name];
        if (!rs) continue;
        if (rs.enabled === "0") continue;
        let t = rs.type ?? "remote";
        let d = reg.get("rule_set", t);
        let entry = (d != null) ? filler.build(d, rs) : { type: t, tag: name };

        if (t === "remote") {
            entry.format = detect_format(rs);
            let iv = +(rs.update_interval ?? "0");
            if (iv > 0) entry.update_interval = sprintf("%ds", int(iv));
            else if (length(rs.update_interval ?? "") && iv != iv)   // non-empty but NaN
                warn(sprintf("ruleset.uc: '%s' update_interval '%s' is not numeric seconds; omitting\n", name, rs.update_interval));
        } else if (t === "local") {
            entry.format = detect_format(rs);
        } else if (t === "inline") {
            delete entry.format;          // inline has no format
            let refs = rs.rules ?? [];
            if (type(refs) === "string") refs = [ refs ];
            // Guards mirror route.uc's logical-inlining loop (null/logical/disabled).
            // Kept duplicated intentionally: the two containers (logical rule vs
            // inline rule_set) have different validity semantics; only 2 call sites.
            let sub = [];
            for (let n in refs) {
                let rr = rr_by_name[n];
                if (rr == null) continue;
                if ((rr.type ?? "default") === "logical") continue;
                if (rr.enabled === "0") continue;
                let h = headless.build(rr);
                if (length(keys(h))) push(sub, h);
            }
            // `rules` is UI-only refs in UCI (no json_key); expand to headless JSON here.
            entry.rules = sub;
        }
        push(rule_sets, entry);
    }
    return rule_sets;
}

return { build_rule_sets };
