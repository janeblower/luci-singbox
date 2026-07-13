// lib/ruleset.uc — sing-box route.rule_set definitions for referenced rule-sets.
//
// remote/local entries are built ENTIRELY by the descriptor + filler now, `format`
// and `update_interval` included (post() sniffs the format from the source's
// extension; coerce:"duration" spells the interval as "<n>s"). They used to be
// bolted on here, after the filler had run — which meant the JSON editor exported
// a rule-set object the generated config did not match, and could not invert those
// two keys at all.
//
// What is left here is what genuinely CANNOT live in a descriptor, because it
// depends on other sections: inline entries embed headless rules built from the
// referenced default route_rule sections, and a dangling download_detour is
// dropped against the set of outbounds that actually exist.

let reg      = require("builder.route.registry");
let filler   = require("builder._filler");
let headless = require("builder.route.headless");

// build_rule_sets(cur, referenced_names) -> [{tag, type, ...}, ...]
function build_rule_sets(cur, referenced_names, valid_ob) {
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

        if (t === "inline") {
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
                // Mirror route.uc's logical loop: a rule_set matcher is excluded
                // from a headless rule (NO_HL), so warn before it vanishes
                // silently rather than dropping the matcher without a trace.
                if (rr.rule_set != null && length(rr.rule_set))
                    warn(sprintf("ruleset.uc: inline rule-set '%s' sub-rule '%s' has a rule_set matcher; not valid in an inline rule-set rule, dropped\n", name, n));
                let h = headless.build(rr);
                if (length(keys(h))) push(sub, h);
            }
            // `rules` is UI-only refs in UCI (no json_key); expand to headless JSON here.
            entry.rules = sub;
        }
        // download_detour names an outbound used to FETCH a remote rule-set; an
        // unknown tag is a dangling reference sing-box refuses to start on.
        // Unlike every other outbound ref (route_rule/route_default/dns.final),
        // this one was never checked. Drop it when it isn't a defined outbound.
        if (length(entry.download_detour ?? "") && valid_ob != null && !valid_ob[entry.download_detour]) {
            warn(sprintf("ruleset.uc: rule-set '%s' download_detour '%s' is not a defined outbound; dropping it\n", name, entry.download_detour));
            delete entry.download_detour;
        }
        push(rule_sets, entry);
    }
    return rule_sets;
}

return { build_rule_sets };
