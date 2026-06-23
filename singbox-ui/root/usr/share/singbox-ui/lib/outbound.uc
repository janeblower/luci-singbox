// lib/outbound.uc — sing-box `outbounds` builder + subscription glue. After
// Phase E2 every UI-creatable protocol has a descriptor; this file dispatches
// via the registry and never falls back to a hand-coded switch. The
// share-link / subscription URL parsers were split into lib/sharelink.uc
// (SRP, S4-10) and are re-exported below for back-compat.

const TMPDIR = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";

let fs = require("fs");
let helpers = require("helpers");
let reg = require("builder.protocols.registry");
let sharelink = require("sharelink");
let filler = require("builder._filler");

// Eagerly load every active descriptor so register() fires. Anything not
// listed here is permanently absent from the UI and the JSON. S2.1: each
// require() is wrapped so a single malformed descriptor file (its register()
// asserting) logs+skips instead of throwing through require() and aborting
// config generation for ALL protocols. The robustness net try_register
// documents now actually exists on the production path.
for (let _m in ["builder.protocols.direct", "builder.protocols.shadowsocks", "builder.protocols.vless",
                "builder.protocols.trojan", "builder.protocols.hysteria2", "builder.protocols.hysteria",
                "builder.protocols.tuic", "builder.protocols.anytls", "builder.protocols.shadowtls",
                "builder.protocols.json_raw",
                "builder.protocols.socks", "builder.protocols.http", "builder.protocols.vmess",
                "builder.protocols.ssh", "builder.protocols.naive",
                "builder.protocols.groups"]) {
	try { require(_m); }
	catch (e) { warn(sprintf("outbound.uc: descriptor '%s' failed to load; skipping: %s\n", _m, e)); }
}

const s_opt = helpers.s_opt;

// Share-link parsers live in lib/sharelink.uc (SRP, S4-10). Re-export
// parse_proxy_url so existing callers — build_outbounds below, the rpcd /
// export_section paths, and require("outbound").parse_proxy_url in tests —
// keep working unchanged.
const parse_proxy_url = sharelink.parse_proxy_url;

// build_constructor_for(s, proto) — descriptor-only. Returns null if no
// descriptor is registered for the kind/proto pair.
function build_constructor_for(s, proto) {
	let d = reg.get("outbound", proto);
	if (d == null) {
		warn(sprintf("outbound.uc: no descriptor for '%s'\n", proto));
		return null;
	}
	// Legacy / escape-hatch descriptors carry emit(); declarative descriptors
	// (trojan/direct outbound, Phase F) build via builder._filler from their
	// fields[] metadata + declared shared blocks. Predicate matches inbound.uc
	// / dns.uc (`type(...) === "function"`) so all dispatch sites agree even if
	// a future descriptor sets emit to a non-function value (BLD-9).
	return (type(d.emit) === "function") ? d.emit(s) : filler.build(d, s);
}

function read_subscription_urls(name) {
	let path = `${TMPDIR}/sub_${name}.txt`;
	let f = fs.open(path, "r");
	if (!f) {
		warn("outbound.uc: subscription state missing: " + path + "\n");
		return [];
	}
	let body = f.read("all") ?? "";
	f.close();
	let urls = [];
	for (let line in split(body, "\n")) {
		let t = trim(line);
		if (length(t)) push(urls, t);
	}
	return urls;
}

function build_outbounds(cur) {
	let outbounds = [];

	// S1.5: guard against duplicate outbound tags. sing-box rejects the whole
	// config at load on a duplicate tag (e.g. a user outbound literally named
	// "mysub__0" colliding with subscription "mysub"'s first child). add_ob
	// emits a clear generator-side warn and skips the collision instead of
	// letting it surface as a cryptic daemon load failure at apply time.
	let seen_tags = {};
	function add_ob(ob) {
		let t = ob.tag;
		if (seen_tags[t]) {
			warn(sprintf("outbound.uc: duplicate outbound tag '%s'; skipping (would break sing-box load)\n", t));
			return;
		}
		seen_tags[t] = true;
		push(outbounds, ob);
	}

	cur.foreach("singbox-ui", "outbound", function(section) {
		if (section.enabled === "0") return;

		let name = section[".name"];
		let kind = s_opt(section, "type");
		if (kind === "") return;          // unmigrated/empty section — skip
		let outbound = null;

		if (kind === "url") {
			let parsed = parse_proxy_url(section.proxy_url ?? "");
			if (parsed) { parsed.tag = name; outbound = parsed; }
		} else if (kind === "direct") {
			// E2: descriptor-owned direct outbound (type=direct in UCI). Binds an
			// interface via the dial shared block (bind_interface, emitted verbatim
			// as a netdev name) — replaced the removed legacy type=interface shorthand.
			outbound = build_constructor_for(section, kind);
		} else if (kind === "json" || kind === "sharelink") {
			// Task 4: raw passthrough types. Their descriptor emit() parses the
			// stored raw_json / raw_link and stamps the section tag. Own dispatch
			// branch (like direct) — not in OUTBOUND_PROXY_KINDS.
			outbound = build_constructor_for(section, kind);
		} else if (kind === "selector" || kind === "urltest") {
			outbound = build_constructor_for(section, kind);
		} else if (helpers.is_outbound_proxy_kind(kind)) {
			outbound = build_constructor_for(section, kind);
		} else if (kind === "subscription") {
			let urls = read_subscription_urls(name);
			if (!length(urls)) return;

			if (section.sub_multi === "1") {
				let children = [];
				let i = 0;
				for (let u in urls) {
					let parsed = parse_proxy_url(u);
					if (!parsed) { i++; continue; }
					let tag = name + "__" + i;
					parsed.tag = tag;
					add_ob(parsed);
					push(children, tag);
					i++;
				}
				if (length(children)) {
					// GEN-3: only "selector"/"urltest" are valid sing-box group
					// types. A stale/hand-edited sub_selector_type would emit an
					// invalid `type` and make sing-box reject the whole config —
					// clamp anything unexpected to the safe default "selector".
					let selector_type = (section.sub_selector_type === "urltest") ? "urltest" : "selector";
					let group = { tag: name, type: selector_type, outbounds: children };
					if (selector_type === "urltest" && section.sub_urltest_url)
						group.url = section.sub_urltest_url;
					add_ob(group);
				}
				return;  // done with this section
			}

			// Single-URL fallback (sub_multi=0): pick the first parseable one.
			for (let u in urls) {
				let parsed = parse_proxy_url(u);
				if (parsed) { parsed.tag = name; outbound = parsed; break; }
			}
		} else {
			warn(sprintf("outbound.uc: unknown type '%s' for '%s'; skipping\n", kind, name));
			return;
		}

		if (!outbound) return;
		add_ob(outbound);
	});

	// GEN-1 / BLD-7: selector & urltest groups carry an `outbounds[]` member
	// list (and selector a `default` target) of OTHER outbound tags. sing-box
	// hard-fails at config load on a group that references a non-existent
	// outbound ("outbound not found") or that has an empty `outbounds`. Nothing
	// validated these — a user who deletes/disables a member, or saves a group
	// before adding members, silently produces a config the daemon refuses to
	// start. Mirror route.uc's ob_ok dangling-drop: prune members to the set of
	// tags that actually exist in the final array (plus the implicit `direct`
	// that generate.uc injects post-build), drop the whole group if it ends up
	// empty, and clear a `default` that doesn't resolve. NOTE: urltest's `url`
	// is an HTTP probe URL, NOT an outbound tag — it must NOT be validated here.
	let valid_tags = { direct: true };
	for (let ob in outbounds) if (length(ob.tag)) valid_tags[ob.tag] = true;
	let pruned = [];
	for (let ob in outbounds) {
		if (ob.type !== "selector" && ob.type !== "urltest") { push(pruned, ob); continue; }
		if (type(ob.outbounds) === "array") {
			let members = [];
			for (let m in ob.outbounds) {
				if (valid_tags[m]) { push(members, m); continue; }
				warn(sprintf("outbound.uc: group '%s' member '%s' is not a defined outbound; dropping member\n", ob.tag, m));
			}
			ob.outbounds = members;
		}
		if (type(ob.outbounds) !== "array" || !length(ob.outbounds)) {
			warn(sprintf("outbound.uc: group '%s' has no valid member outbounds; dropping group (would break sing-box load)\n", ob.tag));
			continue;
		}
		if (length(ob.default ?? "") && !valid_tags[ob.default]) {
			warn(sprintf("outbound.uc: group '%s' default '%s' is not a defined outbound; clearing\n", ob.tag, ob.default));
			delete ob.default;
		}
		push(pruned, ob);
	}

	return pruned;
}

return { build_outbounds, build_constructor_for, parse_proxy_url };
