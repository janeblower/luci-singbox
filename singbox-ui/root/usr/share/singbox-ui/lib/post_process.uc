// lib/post_process.uc — config-level post-processing passes applied AFTER
// all build_* modules have run. Idempotent.
//
// opts.implicit_tags — outbound tags auto-injected by generate.uc.
// References to these from places sing-box validates against the outbound
// graph are removed entirely (key delete, not null) so the serialised JSON
// matches the absent-key contract that test_generate.sh asserts and that
// sing-box 1.12+ expects (it fatally rejects `"detour": "<empty-direct>"`).

function scrub_implicit_refs(config, opts) {
	if (config == null) return config;
	let implicit = (opts != null && type(opts.implicit_tags) === "array")
		? opts.implicit_tags : [];
	if (length(implicit) === 0) return config;

	let is_implicit = {};
	for (let t in implicit) is_implicit[t] = true;

	// GEN-2: route.rules[].outbound / route.final naming an implicit tag are
	// scrubbed ONLY when the tag does NOT resolve to a real outbound in
	// config.outbounds. The sole implicit tag today ("direct") IS injected as a
	// genuine outbound, and routing TO it is valid sing-box — stripping it would
	// leave a route action with no outbound (which sing-box rejects), so a
	// resolvable implicit tag must be left intact. The guard still future-proofs
	// the case the finding flags: a future implicit tag that is NOT materialized
	// as a standalone outbound would be dangling and gets scrubbed. (DNS detour
	// is unconditional: sing-box fatally rejects detour to the implicit/empty
	// direct regardless — see header — so it is not gated on outbound presence.)
	let real_ob = {};
	if (type(config.outbounds) === "array")
		for (let o in config.outbounds) if (length(o.tag)) real_ob[o.tag] = true;
	function scrub_ref(tag) { return is_implicit[tag] && !real_ob[tag]; }

	if (config.dns != null && type(config.dns.servers) === "array") {
		for (let s in config.dns.servers)
			if (s.detour != null && is_implicit[s.detour]) delete s.detour;
	}
	if (config.dns != null && config.dns.detour != null && is_implicit[config.dns.detour])
		delete config.dns.detour;
	if (config.route != null && type(config.route.rules) === "array") {
		for (let r in config.route.rules)
			if (r.outbound != null && scrub_ref(r.outbound)) delete r.outbound;
	}
	if (config.route != null && config.route.final != null && scrub_ref(config.route.final))
		delete config.route.final;

	return config;
}

// FINDING B: a plain outbound's `detour` field pointing at an outbound tag that
// does NOT exist in the emitted config.outbounds (either never defined, or a
// section that was disabled and thus excluded by outbound.uc) is dangling —
// sing-box fatally rejects "detour: <undefined outbound>" at load. Mirror the
// route/dns dangling-drop idiom: delete the key (not null) so the absent-key
// contract holds. Selector/urltest groups use `group_outbounds` (→ `outbounds`),
// a DIFFERENT field already validated in outbound.uc — untouched here. A detour
// to a valid enabled outbound (including a forward reference to a later section,
// since config.outbounds is fully assembled by now) is preserved.
function scrub_dangling_detours(config) {
	if (config == null || type(config.outbounds) !== "array") return config;
	let real_ob = {};
	for (let o in config.outbounds) if (length(o.tag)) real_ob[o.tag] = true;
	for (let o in config.outbounds) {
		if (o.detour != null && length(o.detour) && !real_ob[o.detour]) {
			warn(sprintf("post_process.uc: outbound '%s' detour '%s' is not a defined outbound; scrubbing (would break sing-box load)\n",
			             o.tag ?? "?", o.detour));
			delete o.detour;
		}
	}
	return config;
}

function run_pipeline(config, opts) {
	config = scrub_implicit_refs(config, opts);
	config = scrub_dangling_detours(config);
	// D4: invoke any registered plugin hooks. Failures inside plugins are
	// logged but never propagated (plugin registry guarantees this).
	try {
		let plugins = require("plugins.registry");
		plugins.invoke_on_generate_post(config, opts);
	} catch (_) { /* registry not available — no plugins, no-op */ }
	return config;
}

return { scrub_implicit_refs, scrub_dangling_detours, run_pipeline };
