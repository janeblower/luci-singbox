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
let subformat = require("subformat");
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

// Phase E: load plugin descriptors. Each plugin's init.uc require()s its own
// descriptor modules, which self-register into builder.protocols.registry (and
// the dns/route/settings registries). Failures are isolated by discovery.
try { require("plugins.discovery").load_all(); }
catch (e) { warn(sprintf("outbound.uc: plugin discovery failed: %s\n", e)); }

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
	// A line in sub_<name>.txt is EITHER a share-link URI (the historical form,
	// still what a uri-list feed produces) OR a JSON node record — Clash YAML and
	// sing-box JSON feeds have no share-link to write down. subformat.parse_node
	// reads both, and the call sites below must never care which.
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

// read_subscription_groups(name) — the group-record counterpart of
// read_subscription_urls (Phase C). A sub_<name>.txt line is either a node
// (share-link or JSON {o}) or a JSON group record {g,n,m}; parse_group returns
// null for the former, so node lines fall away and only provider
// urltest/selector groups come through. read_subscription_urls stays node-only
// for back-compat.
function read_subscription_groups(name) {
	let path = `${TMPDIR}/sub_${name}.txt`;
	let f = fs.open(path, "r");
	if (!f) return [];
	let body = f.read("all") ?? "";
	f.close();
	let recs = [];
	for (let line in split(body, "\n")) {
		let g = subformat.parse_group(line);
		if (g) push(recs, g);
	}
	return recs;
}

// outbound-meta side-car: tag -> { name, type, link }. The sing-box JSON has
// nowhere to keep a human-readable node name (the tag must stay ASCII-safe and
// is referenced by route rules), so the display name — plus the originating
// share-link, for the dashboard's copy-link button — lives here and is served
// by rpcd's `outbound_meta`. Mode 0600: `link` carries the node's password/uuid
// (the WARP-key audit finding: never leave a credential world-readable).
const META_PATH = `${TMPDIR}/outbound-meta.json`;

function write_meta(meta) {
	fs.mkdir(TMPDIR, 0o755);
	let f = fs.open(META_PATH, "w", 0o600);
	if (!f) { warn("outbound.uc: cannot write " + META_PATH + "\n"); return; }
	f.write(sprintf("%J", meta));
	f.close();
	fs.chmod(META_PATH, 0o600);   // a pre-existing file keeps its old mode on open()
}

// meta_entry — one side-car record. `country` (ISO-3166 alpha-2, from the flag
// emoji providers put in front of the node name) is what the dashboard turns
// into a badge; omitted when the name carries no flag.
function meta_entry(nm, ob, link) {
	let e = { name: nm, type: ob.type, link: link };
	let c = sharelink.country_from_flag_emoji(nm);
	if (c) e.country = c;
	return e;
}

// A user-supplied regex must never abort config generation: an unclosed bracket
// throws out of regexp(). Compile once, warn, and treat a broken pattern as
// "filter not set" — same as an empty field.
function compile_filter(pat, what, sname) {
	if (!length(pat ?? "")) return null;
	try { return regexp(pat); }
	catch (e) {
		warn(sprintf("outbound.uc: subscription '%s': invalid %s /%s/: %s; ignoring this filter\n",
			sname, what, pat, e));
		return null;
	}
}

// filter_nodes — sub_include_regex / sub_exclude_regex / sub_include_countries,
// all applied to the human-readable display_name (never to the tag: the tag is
// content-derived and is what the user's selector pick is pinned to).
// If the filters leave NOTHING, that is a user error in the pattern, not an
// intent to empty the group: an empty group is dropped downstream, taking the
// subscription out of routing without a word. Keep every node and shout in the
// log instead — a working tunnel plus a loud complaint beats a silent outage.
function filter_nodes(nodes, s, sname) {
	let inc = compile_filter(s.sub_include_regex, "sub_include_regex", sname);
	let exc = compile_filter(s.sub_exclude_regex, "sub_exclude_regex", sname);

	let want = {}, n_want = 0;
	for (let c in split(s.sub_include_countries ?? "", ",")) {
		let t = uc(trim(c));
		if (length(t)) { want[t] = true; n_want++; }
	}

	if (!inc && !exc && !n_want) return nodes;

	let kept = [];
	for (let n in nodes) {
		let dn = n.display_name ?? "";
		if (inc && !match(dn, inc)) continue;
		if (exc && match(dn, exc)) continue;
		if (n_want && !want[sharelink.country_from_flag_emoji(dn) ?? ""]) continue;
		push(kept, n);
	}
	if (!length(kept)) {
		warn(sprintf("outbound.uc: subscription '%s': filters matched 0 of %d nodes; " +
			"keeping ALL nodes (an empty group would drop the subscription from routing) — " +
			"check sub_include_regex/sub_exclude_regex/sub_include_countries\n",
			sname, length(nodes)));
		return nodes;
	}
	return kept;
}

function build_outbounds(cur) {
	let outbounds = [];
	let meta = {};

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
			return false;
		}
		seen_tags[t] = true;
		push(outbounds, ob);
		return true;
	}

	cur.foreach("singbox-ui", "outbound", function(section) {
		if (section.enabled === "0") return;

		let name = section[".name"];
		let kind = s_opt(section, "type");
		if (kind === "") return;          // unmigrated/empty section — skip
		let outbound = null;

		if (kind === "url") {
			let p = sharelink.parse_proxy_link(section.proxy_url ?? "");
			if (p) {
				p.outbound.tag = name;
				outbound = p.outbound;
				meta[name] = meta_entry(p.display_name || name, outbound, p.link);
			}
		} else if (kind === "subscription") {
			let urls = read_subscription_urls(name);
			if (!length(urls)) return;

			if (section.sub_multi === "1") {
				let nodes = [];
				for (let u in urls) {
					let p = subformat.parse_node(u);
					if (p) push(nodes, p);
				}
				nodes = filter_nodes(nodes, section, name);
				let prefix = section.sub_node_prefix ?? "";

				let children = [];
				let name_to_tag = {};     // provider display-name -> our tag (same subscription only)
				let pending_detour = [];  // { ob, name } resolved after all tags are known
				for (let p in nodes) {
					// Tag from CONTENT, not from position: a provider reordering
					// its node list must not move the user's selector pick onto
					// another server. Two nodes that really are identical collide
					// on the same hash — suffix them instead of dropping one (a
					// dropped member would just vanish from the group).
					// sub_node_prefix decorates the DISPLAY name only: putting it in
					// the tag would re-tag every node and move the user's pick.
					let base = name + "__" + sharelink.content_tag(p.outbound);
					let tag = base, n = 2;
					while (seen_tags[tag]) { tag = sprintf("%s_%d", base, n); n++; }
					p.outbound.tag = tag;
					if (!add_ob(p.outbound)) continue;
					push(children, tag);
					// First name wins on a duplicate display name (rare, provider-side).
					let dn = p.display_name ?? tag;
					if (!(dn in name_to_tag)) name_to_tag[dn] = tag;
					if (p.detour_name != null) push(pending_detour, { ob: p.outbound, name: p.detour_name });
					meta[tag] = meta_entry(prefix + (p.display_name || tag), p.outbound, p.link);
				}
				// Resolve each detour STRICTLY to a same-subscription node. Unresolved
				// (direct/block/foreign/typo) -> dropped, logged. This is the leak fix's
				// generate-side half and the map groups will reuse (Phase C).
				// A2 detour resolution; also record which leaf each resolved
				// detour targets so sub_hide_grouped_nodes can hide detour-only
				// leaves (a leaf reachable only as another node's detour is noise
				// in the top-level selector).
				let detour_target = {};
				for (let pd in pending_detour) {
					let target = name_to_tag[pd.name];
					if (target != null) { pd.ob.detour = target; detour_target[target] = true; }
					else warn(sprintf("outbound.uc: subscription '%s': dropping detour to '%s' (not a node of this subscription)\n", name, pd.name));
				}
				// Phase C: rebuild the provider's urltest/selector groups as
				// namespaced outbounds. Off by default (sub_import_groups) so an
				// existing subscription's flat selector stays byte-for-byte the same.
				let import_groups = (section.sub_import_groups === "1");
				let hide_grouped  = (section.sub_hide_grouped_nodes ?? "1") === "1";
				let trust         = (section.sub_trust_provider === "1");
				let max_depth     = int(section.sub_group_max_depth ?? "3") || 3;

				let group_tags = [];   // emitted group tags, provider order

				if (import_groups) {
					let recs = read_subscription_groups(name);
					// Pass 1: give each group record a namespaced tag and index it by
					// provider NAME (content_tag hashes node CONTENT fields, all empty
					// for a group object, so it would collide every group onto one
					// tag). Dedup on `assigned`, NOT seen_tags: no group tag is in
					// seen_tags yet at pass-1 time, so two provider groups sharing a
					// name must be told apart here or the second's add_ob silently
					// loses to the first (M-1).
					let group_rec_by_name = {};   // provider name -> record
					let assigned = {};            // gtag -> true
					let gi = 0;
					for (let r in recs) {
						let slug = sharelink.name_slug(r.name ?? sprintf("g%d", gi)); gi++;
						let gtag = name + "__grp__" + slug, k = 2;
						while (assigned[gtag]) { gtag = sprintf("%s__grp__%s_%d", name, slug, k); k++; }
						assigned[gtag] = true;
						r._tag = gtag;
						if (r.name != null && !(r.name in group_rec_by_name)) group_rec_by_name[r.name] = r;
					}
					// Resolve a group-typed member by BUILDING it depth-first and
					// using the return value (tag on success, null on drop) — NOT by a
					// static tag lookup. A static tag would dangle the moment the child
					// group drops (empty/add_ob-fail) and would make the depth/cycle
					// guards inert (the recursion below is never entered). C-1 + I-1.
					let built = {};       // gtag -> emitted tag | null (PERMANENT drop). Not set for depth/cycle PATH-drops.
					let building = {};    // gtag -> true while on the DFS stack (cycle break)
					let resolve_ref, build_group;   // forward: ucode resolves let-bound fns in order
					resolve_ref = function(nm, depth) {
						if (nm in name_to_tag) return name_to_tag[nm];                          // same-sub leaf
						if (nm in group_rec_by_name) return build_group(group_rec_by_name[nm], depth + 1); // nested group, on demand
						if (trust && (nm === "direct" || nm === "block")) return nm;            // escape hatch only
						return null;
					};
					build_group = function(r, depth) {
						if (r._tag in built) return built[r._tag];   // memo: success or permanent drop
						if (depth > max_depth) return null;          // depth: path-drop, do NOT memo (may build shallower elsewhere)
						if (building[r._tag]) return null;           // cycle: break this path, do NOT memo
						building[r._tag] = true;
						let kids = [];
						for (let mnm in r.group.members) {
							let t = resolve_ref(mnm, depth);
							if (t == null) {
								warn(sprintf("outbound.uc: subscription '%s': group '%s' drops member '%s' (unresolved)\n", name, r.name ?? r._tag, mnm));
								continue;
							}
							push(kids, t);
						}
						building[r._tag] = false;
						if (!length(kids)) { built[r._tag] = null; return null; }   // empty group: permanent drop
						let gt = (lc(r.group.type) === "selector") ? "selector" : "urltest";
						let gob = { tag: r._tag, type: gt, outbounds: kids };
						// url/interval/tolerance: user override (main-level field) wins,
						// else provider, else builtin. selector `default` only when it
						// resolves within the sub (build it too — no dangling default).
						if (gt === "urltest") {
							let u = (section.sub_urltest_url != null && section.sub_urltest_url !== "")
								? section.sub_urltest_url : (r.group.url ?? null);
							if (u != null) gob.url = u;
							if (r.group.interval != null)  gob.interval = r.group.interval;
							if (r.group.tolerance != null) gob.tolerance = r.group.tolerance;
						} else if (r.group["default"] != null) {
							let d = resolve_ref(r.group["default"], depth);
							if (d != null) gob["default"] = d;
						}
						if (!add_ob(gob)) { built[r._tag] = null; return null; }
						push(group_tags, r._tag);
						meta[r._tag] = { name: r.name ?? r._tag, type: gt, link: null };
						built[r._tag] = r._tag;
						return r._tag;
					};
					for (let r in recs) build_group(r, 1);
				}

				// GEN-3: only "selector"/"urltest" are valid sing-box group types.
				// A stale/hand-edited sub_selector_type would emit an invalid `type`
				// and make sing-box reject the whole config — clamp to "selector".
				let selector_type = (section.sub_selector_type === "urltest") ? "urltest" : "selector";
				let main_children;
				if (import_groups && length(group_tags)) {
					// main replaces the provider's top selector. Classify every kid of
					// every EMITTED group: a kid that is itself a group tag makes that
					// group non-top-level (referenced); a leaf kid is a "grouped leaf".
					let group_tag_set = {};
					for (let gt in group_tags) group_tag_set[gt] = true;
					let referenced = {};     // group tags used as a member of another group
					let grouped_leaf = {};   // leaf tags claimed by some emitted group
					for (let gt in group_tags) {
						let ob = null; for (let x in outbounds) if (x.tag === gt) ob = x;
						if (ob) for (let c in ob.outbounds) {
							if (group_tag_set[c]) referenced[c] = true;
							else grouped_leaf[c] = true;
						}
					}
					// Children = top-level groups + leaves per the hide flag. Hiding is
					// view-only: every leaf is still emitted via add_ob and stays
					// routable. hide='1' (default) drops grouped + detour-only leaves;
					// hide='0' also lists every leaf as a direct main child IN ADDITION
					// to its group (valid in sing-box; matches forkop
					// hide_urltest_group_outbounds).
					main_children = [];
					for (let gt in group_tags) if (!referenced[gt]) push(main_children, gt);
					for (let lt in children) {
						if (hide_grouped && (grouped_leaf[lt] || detour_target[lt])) continue;
						push(main_children, lt);
					}
				} else {
					main_children = children;
				}
				if (length(main_children)) {
					let group = { tag: name, type: selector_type, outbounds: main_children };
					if (selector_type === "urltest" && section.sub_urltest_url)
						group.url = section.sub_urltest_url;
					add_ob(group);
				}
				return;  // done with this section
			}

			// Single-URL fallback (sub_multi=0): pick the first parseable one.
			for (let u in urls) {
				let p = subformat.parse_node(u);
				if (!p) continue;
				p.outbound.tag = name;
				outbound = p.outbound;
				meta[name] = meta_entry(p.display_name || name, outbound, p.link);
				break;
			}
		} else if (reg.get("outbound", kind)) {
			// Every descriptor-backed kind — the proxy protocols, `direct`, the raw
			// passthroughs (json/sharelink) and the groups (selector/urltest) — is
			// built the same way. The registry IS the list of what exists; asking it
			// beats keeping a second hand-written copy of the same set in helpers.uc.
			outbound = build_constructor_for(section, kind);
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
	// Groups can nest, so one pass is not enough: dropping an emptied group B
	// invalidates every reference to B — including one held by another group A.
	// A snapshot of valid_tags taken before the pass still contains B, so A kept a
	// member sing-box cannot resolve ("outbound not found" -> the daemon refuses to
	// start), which is the exact failure this prune exists to prevent. Re-derive
	// the tag set and repeat until a pass drops nothing. Terminates: every pass but
	// the last removes at least one group, and members only ever shrink.
	let pruned = outbounds;
	while (true) {
		let valid_tags = { direct: true };
		for (let ob in pruned) if (length(ob.tag)) valid_tags[ob.tag] = true;

		let next = [];
		for (let ob in pruned) {
			if (ob.type !== "selector" && ob.type !== "urltest") { push(next, ob); continue; }
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
			push(next, ob);
		}

		let stable = (length(next) === length(pruned));
		pruned = next;
		if (stable) break;
	}

	// Side-car only ever describes outbounds that actually survived the prune.
	let live = {};
	for (let ob in pruned) if (meta[ob.tag]) live[ob.tag] = meta[ob.tag];
	write_meta(live);

	return pruned;
}

return { build_outbounds, build_constructor_for, parse_proxy_url };
