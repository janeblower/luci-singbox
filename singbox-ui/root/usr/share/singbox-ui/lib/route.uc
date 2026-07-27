// lib/route.uc — sing-box route.rules + final outbound; reports referenced
// rulesets. Per-rule JSON is built declaratively via builder.route descriptors
// + builder._filler; this module owns the cross-cutting logic: auto hijack-dns,
// ruleset-ref resolution + referenced[] tracking, dangling-outbound drop,
// logical inlining, and top-level exclusion of consumed sub-rules.

let reg      = require("builder.route.registry");   // eager-loads route_rule/rule_set descriptors
let filler   = require("builder._filler");
let headless = require("builder.route.headless");
let match    = require("builder._shared.match");
let helpers  = require("helpers");

// Matcher json_keys a route rule can carry (the single match.uc source), minus
// `invert` which is a modifier, not a matcher. Used to detect a rule left with
// no matcher after rule-set resolution — which in sing-box matches ALL traffic.
let MATCHER_KEYS = {};
for (let f in match.fields("route")) if (f.json_key !== "invert") MATCHER_KEYS[f.json_key] = true;

// build_route_rules(cur, valid_ob) -> { rules, final, referenced }
function build_route_rules(cur, valid_ob) {
    let rules = [];
    let referenced = [];
    let seen = {};
    function ob_ok(tag) { return !valid_ob || valid_ob[tag]; }

    // hijack-dns from a transparent inbound (must precede user rules). Both
    // tproxy and tun carry a `hijack_dns` field: the mechanism that gets the
    // query here differs (our nft rules vs the tunnel itself), but the route
    // action it asks for is the same one — so it is decided in the one place
    // both protocols meet, not branched per protocol.
    let hijack = false;
    cur.foreach("singbox-ui", "inbound", function(s) {
        if (s.enabled === "0") return;
        if (s.protocol !== "tproxy" && s.protocol !== "tun") return;
        if (s.hijack_dns === "1") hijack = true;
    });
    if (hijack) push(rules, { protocol: "dns", action: "hijack-dns" });

    cur.foreach("singbox-ui", "inbound", function(s) {
        if (s.enabled === "0") return;
        if (s.protocol !== "direct") return;
        if (s.dns_listener !== "1") return;
        push(rules, { inbound: s[".name"], action: "hijack-dns" });
    });

    // ruleset enabled lookup (honours the builtin master switch — helpers.ruleset_active).
    let rs_enabled = {};
    cur.foreach("singbox-ui", "ruleset", function(s) { rs_enabled[s[".name"]] = helpers.ruleset_active(cur, s); });

    // index route_rule sections; collect the consumed set (refs from logical
    // route_rules and inline rulesets) so consumed default rules are NOT emitted
    // top-level.
    let rr_by_name = {};
    cur.foreach("singbox-ui", "route_rule", function(s) { rr_by_name[s[".name"]] = s; });

    let consumed = {};
    cur.foreach("singbox-ui", "route_rule", function(s) {
        if (s.enabled === "0") return;
        if ((s.type ?? "default") !== "logical") return;
        for (let n in helpers.as_array(s.rules)) consumed[n] = true;
    });
    cur.foreach("singbox-ui", "ruleset", function(s) {
        if (s.enabled === "0") return;
        if ((s.type ?? "remote") !== "inline") return;
        for (let n in helpers.as_array(s.rules)) consumed[n] = true;
    });

    // resolve+track rule_set matcher refs on a built rule (drop disabled/missing).
    function resolve_rulesets(rule) {
        if (rule.rule_set == null) return false;
        let resolved = [];
        for (let n in rule.rule_set) {
            if (!rs_enabled[n]) continue;
            if (!seen[n]) { push(referenced, n); seen[n] = true; }
            push(resolved, n);
        }
        if (length(resolved)) { rule.rule_set = resolved; return false; }
        delete rule.rule_set;
        return true;   // had a rule_set matcher, all refs disabled/missing -> stripped
    }

    // Every dns_server tag a rule may legitimately name. action=resolve's
    // `server` was the ONE cross-section reference with no dangling guard
    // anywhere: disable or delete the dns_server it points at and the tag went
    // straight into the config, where sing-box refuses the whole file.
    let dns_ok_tags = {};
    cur.foreach("singbox-ui", "dns_server", function(s) {
        if (s.enabled === "0") return;
        dns_ok_tags[s[".name"]] = true;
    });

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
        // resolve: CLEAR the dangling tag rather than drop the rule. `server` is
        // optional for resolve — without it sing-box falls back to the default
        // resolver — so keeping the rule preserves the operator's intent
        // ("resolve here"), while dropping it would silently change routing.
        if (rule.action === "resolve" && length(rule.server ?? "") && !dns_ok_tags[rule.server]) {
            warn(sprintf("route.uc: route_rule '%s' server '%s' is not an enabled dns_server; falling back to the default resolver\n", name, rule.server));
            delete rule.server;
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
            for (let n in helpers.as_array(s.rules)) {
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

        // Per-rule bypass needs sing-box 1.13+ (route_default degrades the same
        // way). Unlike route_default's bypass it carries no outbound, so there is
        // nothing to degrade INTO on an older core — 1.12 fatally rejects the
        // unknown action, so drop the rule and warn. Fail-safe: the matched
        // traffic just follows the remaining rules / the final route instead of
        // taking the whole config down. Fail-open on an unknown core version.
        if (rule.action === "bypass" && !helpers.core_at_least("1.13")) {
            warn(sprintf("route.uc: route_rule '%s' action=bypass needs sing-box 1.13+ (running %s); dropping the rule\n",
                         name, helpers.core_version()));
            return;
        }

        // action_ok first: resolve_rulesets() marks the sets it sees as `referenced`,
        // and a referenced set is emitted as a top-level (remote) rule_set that
        // sing-box then fetches in the background. Running it on a rule that
        // action_ok is about to drop made us fetch rule-sets nothing uses.
        if (!action_ok(rule, name)) return;
        let stripped = resolve_rulesets(rule);
        // If a rule's only matcher was a rule_set that resolve_rulesets fully
        // stripped (all referenced sets disabled/missing) it is left with just an
        // action — and a matcher-less rule matches ALL traffic in sing-box,
        // silently turning a scoped rule into a catch-all (e.g. reject- or
        // route-everything). Drop it rather than emit the catch-all. A rule
        // authored WITHOUT any rule_set (e.g. a global sniff) never strips, so it
        // is left untouched.
        if (stripped && t !== "logical") {
            let has_matcher = false;
            for (let k in MATCHER_KEYS) if (rule[k] != null) { has_matcher = true; break; }
            if (!has_matcher) {
                warn(sprintf("route.uc: route_rule '%s' lost its only matcher (rule-set(s) disabled/missing); dropping to avoid a catch-all\n", name));
                return;
            }
        }
        push(rules, rule);
    });

    // route_default -> final outbound / trailing reject / trailing bypass.
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
        } else if (a === "bypass") {
            // `final` is only a tag, so bypass cannot be expressed as one — it goes
            // out as a trailing matcher-less rule, which in sing-box matches all
            // traffic and therefore lands in the same place a `final` would.
            //
            // With an outbound set, sing-box treats bypass exactly as `route` for
            // every connection that did not come from auto_redirect — and it lets
            // the kernel take the short path for the ones that did. That is the
            // point of shipping it as the default. WITHOUT an outbound, though, the
            // rule is SKIPPED outside auto-redirect, so the user would be left with
            // no default route at all: warn rather than let that pass quietly.
            let ob = rd.outbound ?? "";
            if (length(ob) && !ob_ok(ob)) {
                warn(sprintf("route.uc: route_default outbound '%s' is not a defined outbound; emitting bypass with no outbound\n", ob));
                ob = "";
            }
            if (!length(ob))
                warn("route.uc: route_default action=bypass with no outbound; sing-box skips this rule outside auto-redirect, leaving no default route\n");

            // bypass landed in sing-box 1.13, and 1.12 does not ignore an unknown
            // action — it refuses the whole config, so the service never starts. The
            // seed config ships action=bypass, which would brick a fresh install on
            // an older core. Degrade to `route`, which is what bypass does here
            // anyway once auto_redirect is off the table. Fail-open: an unknown core
            // version gates nothing.
            if (!helpers.core_at_least("1.13")) {
                warn(sprintf("route.uc: route_default action=bypass needs sing-box 1.13+ (running %s); emitting action=route instead\n",
                             helpers.core_version()));
                if (length(ob)) final = ob;
                else warn("route.uc: …and there is no outbound to fall back to, so no default route is set\n");
            } else {
                push(rules, { action: "bypass", outbound: ob });
            }
        }
    }

    return { rules, final, referenced };
}

return { build_route_rules };
