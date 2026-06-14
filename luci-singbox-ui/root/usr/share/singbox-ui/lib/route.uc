// lib/route.uc — sing-box route.rules + final outbound; reports referenced
// rulesets. Per-rule JSON is built declaratively via builder.route descriptors
// + builder._filler; this module owns the cross-cutting logic: auto hijack-dns,
// ruleset-ref resolution + referenced[] tracking, dangling-outbound drop,
// logical inlining, and top-level exclusion of consumed sub-rules.

let reg      = require("builder.route.registry");   // eager-loads route_rule/rule_set descriptors
let filler   = require("builder._filler");
let headless = require("builder.route.headless");

// build_route_rules(cur, valid_ob) -> { rules, final, referenced }
function build_route_rules(cur, valid_ob) {
    let rules = [];
    let referenced = [];
    let seen = {};
    function ob_ok(tag) { return !valid_ob || valid_ob[tag]; }

    // hijack-dns from tproxy inbounds (must precede user rules).
    let hijack = false;
    cur.foreach("singbox-ui", "inbound", function(s) {
        if (s.enabled === "0") return;
        if (s.protocol === "tproxy" && s.hijack_dns === "1") hijack = true;
    });
    if (hijack) push(rules, { protocol: "dns", action: "hijack-dns" });

    cur.foreach("singbox-ui", "inbound", function(s) {
        if (s.enabled === "0") return;
        if (s.protocol !== "direct") return;
        if (s.dns_listener !== "1") return;
        push(rules, { inbound: s[".name"], action: "hijack-dns" });
    });

    // ruleset enabled lookup.
    let rs_enabled = {};
    cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = (s.enabled !== "0"); });

    // index route_rule sections; collect the consumed set (refs from logical
    // route_rules and inline rulesets) so consumed default rules are NOT emitted
    // top-level.
    let rr_by_name = {};
    cur.foreach("singbox-ui", "route_rule", function(s) { rr_by_name[s[".name"]] = s; });

    function ref_list(s) {
        let refs = s.rules ?? [];
        if (type(refs) === "string") refs = [ refs ];
        return refs;
    }
    let consumed = {};
    cur.foreach("singbox-ui", "route_rule", function(s) {
        if (s.enabled === "0") return;
        if ((s.type ?? "default") !== "logical") return;
        for (let n in ref_list(s)) consumed[n] = true;
    });
    cur.foreach("singbox-ui", "ruleset", function(s) {
        if (s.enabled === "0") return;
        if ((s.type ?? "remote") !== "inline") return;
        for (let n in ref_list(s)) consumed[n] = true;
    });

    // resolve+track rule_set matcher refs on a built rule (drop disabled/missing).
    function resolve_rulesets(rule) {
        if (rule.rule_set == null) return;
        let resolved = [];
        for (let n in rule.rule_set) {
            if (!rs_enabled[n]) continue;
            if (!seen[n]) { push(referenced, n); seen[n] = true; }
            push(resolved, n);
        }
        if (length(resolved)) rule.rule_set = resolved;
        else delete rule.rule_set;
    }

    // validate action target; return false to drop the rule.
    function action_ok(rule, name) {
        // Only `route` requires an outbound. reject/hijack-dns/sniff/resolve/
        // route-options carry no outbound (route-options' outbound field is
        // filler-gated to action=route), so they pass through unvalidated.
        if (rule.action === "route") {
            if (!length(rule.outbound ?? "")) {
                warn(sprintf("route.uc: route_rule '%s' action=route with no outbound; dropping\n", name));
                return false;
            }
            if (!ob_ok(rule.outbound)) {
                warn(sprintf("route.uc: route_rule '%s' outbound '%s' is not a defined outbound; dropping\n", name, rule.outbound));
                return false;
            }
        }
        return true;
    }

    cur.foreach("singbox-ui", "route_rule", function(s) {
        if (s.enabled === "0") return;
        let t = s.type ?? "default";
        let name = s[".name"];
        if (t === "default" && consumed[name]) return;   // consumed -> nested only

        let d = reg.get("route_rule", t);
        if (d == null) {
            warn(sprintf("route.uc: unknown route_rule type '%s' for '%s'; skipping\n", t, name));
            return;
        }
        let rule = filler.build(d, s);

        if (t === "logical") {
            rule.type = "logical";
            let sub = [];
            for (let n in ref_list(s)) {
                let rs = rr_by_name[n];
                if (rs == null) continue;
                if ((rs.type ?? "default") === "logical") continue;   // only default refs
                if (rs.enabled === "0") continue;
                if (rs.rule_set != null && length(rs.rule_set))
                    warn(sprintf("route.uc: logical '%s' sub-rule '%s' has a rule_set matcher; not valid in a logical sub-rule, dropped\n", name, n));
                let h = headless.build(rs);
                if (length(keys(h))) push(sub, h);
            }
            if (!length(sub)) return;   // empty logical -> skip
            rule.rules = sub;
        }

        resolve_rulesets(rule);
        if (!action_ok(rule, name)) return;
        push(rules, rule);
    });

    // route_default -> final outbound / trailing reject.
    let final = null;
    let rd = cur.get_all("singbox-ui", "route_default");
    if (rd) {
        let a = rd.action ?? "route";
        if (a === "route") {
            final = rd.outbound ?? null;
            if (final && !ob_ok(final)) {
                warn(sprintf("route.uc: route_default outbound '%s' is not a defined outbound; omitting final\n", final));
                final = null;
            }
        } else if (a === "reject") {
            push(rules, { action: "reject" });
        }
    }

    return { rules, final, referenced };
}

return { build_route_rules };
