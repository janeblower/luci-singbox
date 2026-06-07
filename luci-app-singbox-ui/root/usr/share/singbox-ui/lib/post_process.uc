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

	if (config.dns != null && type(config.dns.servers) === "array") {
		for (let s in config.dns.servers)
			if (s.detour != null && is_implicit[s.detour]) delete s.detour;
	}
	if (config.dns != null && config.dns.detour != null && is_implicit[config.dns.detour])
		delete config.dns.detour;
	if (config.route != null && type(config.route.rules) === "array") {
		for (let r in config.route.rules)
			if (r.outbound != null && is_implicit[r.outbound]) delete r.outbound;
	}
	if (config.route != null && config.route.final != null && is_implicit[config.route.final])
		delete config.route.final;

	return config;
}

function run_pipeline(config, opts) {
	config = scrub_implicit_refs(config, opts);
	return config;
}

return { scrub_implicit_refs, run_pipeline };
