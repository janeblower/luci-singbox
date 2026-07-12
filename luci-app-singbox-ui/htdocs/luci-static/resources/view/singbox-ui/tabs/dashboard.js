'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.icons as SbIcons';
'require view.singbox-ui.lib.common as SbCommon';

var waitSubRefresh   = SbCommon.waitSubRefresh;
var callClashGet     = SbRpc.callClashGet;
var callClashMutate  = SbRpc.callClashMutate;
var callClashDelay   = SbRpc.callClashDelay;
var callSubStatus    = SbRpc.callSubStatus;
var callRefresh      = SbRpc.callRefresh;
var callOutboundMeta = SbRpc.callOutboundMeta;

function buildDashboard() {
	var state = {
		timer: null, ui: null, loaded: false,
		lastDown: null, lastUp: null, dRate: 0, uRate: 0,
		totDown: 0, totUp: 0, conns: 0, memory: 0, version: '', running: false,
		proxies: {}, proxiesEvery: 0, sortByLatency: false,
		// tag -> { name, type, link } side-car (rpcd outbound_meta). The sing-box
		// tag is ASCII-safe and often a content hash; the human-readable node name
		// ("🇳🇱 Умная локация") only exists here. UNTRUSTED (it comes from the
		// subscription provider) — render through E()/textContent only.
		meta: {},
		subs: {}, subsNow: 0,
		// DASH-1/DASH-4: per-group "latency test in progress" flag. Set while a
		// group's probes run so renderGroups() can disable its Test button and
		// repeated clicks don't stack concurrent probe storms.
		testing: {},
		// group -> { done, total }; the Test button's label span is updated in
		// place from it (see state.ui.labels), never by re-rendering the grid.
		progress: {},
		subUpdating: {},
		// Tag whose selector switch is in flight — its card wears the snake.
		switchingTag: '',
		// UIS-3: flag to suppress periodic fetchProxies while a node switch is
		// pending (between chooseNode's PUT and refreshProxies), preventing the
		// poll from wiping the optimistic selection mid-flight.
		switchPending: false
	};
	var root = E('div', { 'class': 'sb-dashboard' });

	// forkop's prettyBytes: decimal (1000) divisor, 3 significant digits.
	function prettyBytes(n) {
		n = +n || 0;
		if (n < 1000) return n + ' B';
		var u = ['B','KB','MB','GB','TB','PB'];
		var e = Math.min(Math.floor(Math.log(n) / Math.log(1000)), u.length - 1);
		return Number((n / Math.pow(1000, e)).toPrecision(3)) + ' ' + u[e];
	}

	function fetchProxies() {
		return callClashGet('/proxies').then(function (res) {
			if (res && res.status === 'ok') {
				var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
				state.proxies = (d && d.proxies) || {};
			}
		}, function () {
			// Keep the last known groups; a failed refresh must not reject onwards,
			// or chooseNode()'s success-only .then never clears switchPending.
		});
	}
	function fetchMeta() {
		if (!callOutboundMeta) return Promise.resolve();
		return callOutboundMeta().then(function (res) {
			state.meta = (res && res.meta) || {};
		}, function () { /* older backend without outbound_meta: fall back to tags */ });
	}
	function refreshProxies() {
		return Promise.all([ fetchProxies(), fetchMeta() ]).then(repaint);
	}
	// True while any group's latency test is mid-run. The background poll uses
	// this to avoid replacing state.proxies (which would wipe in-flight results).
	function anyTesting() {
		for (var k in state.testing) if (state.testing[k]) return true;
		return false;
	}

	function applySubStatus(res) {
		var map = {};
		var arr = (res && res.subscriptions) || [];
		(Array.isArray(arr) ? arr : []).forEach(function (s) { map[s.name] = s; });
		state.subs = map;
		// DASH-2: prefer the server-supplied `now` (like the status panel)
		// so "updated X ago" stays accurate on routers whose clock drifts
		// from the browser (common without NTP). Falls back to the client
		// clock in agoText() when the backend doesn't emit `now`.
		state.subsNow = (res && +res.now) || 0;
	}

	function fetchSubs() {
		return callSubStatus().then(applySubStatus, function () { /* keep last known */ });
	}
	function refreshSubs() { return fetchSubs().then(repaint); }

	function agoText(ts) {
		if (!ts) return _('never');
		// Use the server clock when the backend supplied one (state.subsNow),
		// else fall back to the browser clock (DASH-2).
		var now = state.subsNow || Math.floor(Date.now() / 1000);
		var secs = now - ts;
		if (secs < 0) secs = 0;
		if (secs < 60)   return _('%ds ago').format(secs);
		if (secs < 3600) return _('%dm ago').format(Math.floor(secs / 60));
		if (secs < 86400)return _('%dh ago').format(Math.floor(secs / 3600));
		return _('%dd ago').format(Math.floor(secs / 86400));
	}

	function fmtExpire(sec) {
		sec = +sec || 0;
		if (!sec) return '';
		var d = new Date(sec * 1000);
		// `sec` comes straight from the provider's Subscription-Userinfo header, which
		// the threat model treats as hostile. A value past ~8.64e12 makes an Invalid
		// Date, whose toISOString() THROWS — and the throw escaped repaint() into
		// poll()'s .catch(showUnreachable), which wiped the dashboard and blamed the
		// Clash API instead. One bad header line bricked the tab until reload.
		if (!isFinite(d.getTime())) return '';
		return d.toISOString().slice(0, 10);
	}

	function updateSub(name) {
		state.subUpdating[name] = true;
		renderGroups();
		function done() { state.subUpdating[name] = false; }
		// async: the RPC returns as soon as the fetch is forked; waitSubRefresh
		// polls sub_status (which also keeps the table live) until the backend's
		// progress side-car reports the run finished.
		return callRefresh('subscriptions', name, true).then(function () {
			return waitSubRefresh(function (res) { applySubStatus(res); repaint(); });
		}).then(function () {
			done();
			return Promise.all([ fetchProxies(), fetchMeta() ]).then(repaint);
		}, function () {
			done();
			renderGroups();
			ui.addNotification(null, E('p', {}, _('Subscription update failed')));
		});
	}

	function setSortByLatency(on) {
		state.sortByLatency = !!on;
		// The button is the only affordance telling the user which order is live,
		// so it carries the state (LuCI's -positive = "on").
		if (state.ui && state.ui.sortBtn)
			state.ui.sortBtn.className = 'cbi-button sb-sort-btn ' +
				(state.sortByLatency ? 'cbi-button-positive' : 'cbi-button-neutral');
		repaint();
	}
	function chooseNode(groupName, member) {
		// optimistic: reflect selection immediately, then resync from /proxies
		if (state.proxies[groupName]) state.proxies[groupName].now = member;
		state.switchPending = true;
		state.switchingTag = member;
		renderGroups();
		function settle() {
			state.switchPending = false;
			state.switchingTag = '';
			renderGroups();
		}
		return callClashMutate('PUT', '/proxies/' + groupName,
		                       JSON.stringify({ name: member }))
			.then(refreshProxies, function () {
				ui.addNotification(null, E('p', {}, _('Failed to switch node')));
				return refreshProxies();
			})
			// Clear on BOTH settle paths: a stuck switchPending freezes the panel on a
			// stale value forever, because poll() then refuses to refetch the groups.
			.then(settle, settle);
	}

	// DASH-1: probe at most TEST_POOL members concurrently and coalesce
	// rendering — a subscription selector can carry 100+ nodes; the old code
	// fired one ubus->clash-api delay RPC per member with no cap AND called
	// renderGroups() (full panel innerHTML='' + rebuild) per result, hammering
	// rpcd and thrashing the DOM O(N^2). Now: a small promise pool bounds
	// in-flight probes, results are written to p.history as they land, and
	// renderGroups() is called once per drained batch (not once per member).
	var TEST_POOL = 8;
	function testGroup(groupName) {
		var grp = state.proxies[groupName];
		if (!grp) return Promise.resolve();
		// Ignore re-clicks while a probe run for this group is already active.
		if (state.testing[groupName]) return Promise.resolve();
		var members = (grp.all || []).filter(function (m) {
			var p = state.proxies[m];
			return p && !isGroupType(p.type);   // don't probe nested groups
		});
		state.testing[groupName] = true;
		state.progress[groupName] = { done: 0, total: members.length };
		renderGroups();   // reflect the disabled/busy Test button immediately

		var idx = 0;
		function tick() {
			// Progress is written straight into the label span. Re-rendering the
			// whole grid per probe would be O(N^2) DOM on a 100-node selector.
			var pr = state.progress[groupName];
			pr.done++;
			var label = state.ui && state.ui.labels && state.ui.labels[groupName];
			if (label) label.textContent = testLabel(pr);
		}
		function probeOne(m) {
			return callClashDelay(m, '', '5000').then(function (res) {
				var ms = 0;
				if (res && res.status === 'ok') {
					var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
					ms = (d && d.delay) || 0;
				}
				var p = state.proxies[m];
				if (p) p.history = [ { delay: ms } ];
				tick();
			}, function () {
				var p = state.proxies[m];
				if (p) p.history = [ { delay: 0 } ];
				tick();
			});
		}
		// One worker drains the shared index, processing a batch then repainting
		// once, so results show up progressively without a per-member rebuild.
		function worker() {
			if (idx >= members.length) return Promise.resolve();
			var batch = members.slice(idx, idx + TEST_POOL);
			idx += batch.length;
			return Promise.all(batch.map(probeOne)).then(function () {
				renderGroups();          // one rebuild per drained batch
				return worker();
			});
		}
		function finish() {
			state.testing[groupName] = false;
			state.progress[groupName] = null;
			renderGroups();
		}
		return worker().then(finish, finish);
	}

	function testLabel(pr) {
		if (!pr || !(pr.total > 0)) return _('Test latency');
		return _('Test latency') + ': ' + Math.min(pr.done, pr.total) + '/' + pr.total;
	}

	// forkop thresholds: no sample -> muted, <800 green, <1500 yellow, else red.
	// (Ours used to be 300/800, which painted a perfectly usable 400ms node red.)
	function latClass(ms) {
		if (!(ms > 0)) return 'sb-lat-none';
		if (ms < 800)  return 'sb-lat-good';
		if (ms < 1500) return 'sb-lat-mid';
		return 'sb-lat-bad';
	}
	function latText(ms) { return (ms > 0) ? (ms + 'ms') : 'N/A'; }
	function isGroupType(t) {
		t = (t || '').toLowerCase();
		return t === 'selector' || t === 'urltest';
	}
	function memberDelay(p) {
		// clash/mihomo /proxies history appends the NEWEST sample LAST, so read the
		// tail. The local Test button writes a single-element array, which the tail
		// read also handles.
		var h = (p && p.history) || null;
		var last = (h && h.length) ? h[h.length - 1] : null;
		return (last && last.delay) || 0;
	}
	function nodeMeta(tag) { return (state.meta && state.meta[tag]) || {}; }
	function displayName(tag) { return nodeMeta(tag).name || tag; }

	var COPYABLE_RE =
		/^(vless|vmess|trojan|ss|ssr|hysteria2?|hy2|tuic|anytls|socks5?):\/\//i;
	function copyLink(link) {
		var p = (typeof navigator !== 'undefined' && navigator.clipboard &&
		         navigator.clipboard.writeText)
			? navigator.clipboard.writeText(link) : Promise.reject();
		return p.catch(function () {
			// LuCI is usually served over plain http, where the async clipboard API
			// is unavailable (secure-context only) — fall back to the old seam.
			var ta = E('textarea', { 'style': 'position:fixed;opacity:0' }, link);
			document.body.appendChild(ta);
			ta.select();
			try { document.execCommand('copy'); } finally { document.body.removeChild(ta); }
		}).then(function () {
			ui.addNotification(null, E('p', {}, _('Proxy link copied')), 'info');
		});
	}

	function showUnreachable() {
		root.innerHTML = '';
		// The mounted chrome (state.ui) was just detached by innerHTML=''.
		// Drop the reference so the next successful poll re-mounts it via
		// repaint()'s `if (!state.ui) mountChrome()` guard.
		state.ui = null;
		root.appendChild(E('em', { 'class': 'sb-dashboard-unavailable' },
			_('Dashboard currently unavailable')));
	}

	// --- widgets -----------------------------------------------------------
	// A widget is a bordered card: bold title, then `key: value` rows. `cls` on a
	// row tints its value via --success/--error, so "stopped" reads red without
	// a second colour system.
	function widget(title, rows) {
		return E('div', { 'class': 'sb-dashboard-widget' }, [
			E('b', { 'class': 'sb-dashboard-widget-title' }, title),
			E('div', { 'class': 'sb-dashboard-widget-rows' },
				rows.filter(Boolean).map(function (r) {
					return E('div', { 'class': 'sb-dashboard-widget-row ' + (r[2] || '') }, [
						E('span', { 'class': 'sb-dashboard-widget-key' }, r[0] + ': '),
						E('span', { 'class': 'sb-dashboard-widget-val' }, r[1])
					]);
				}))
		]);
	}
	function skeleton(cls) {
		return E('div', { 'class': cls + ' sb-skel' });
	}

	function renderWidgets() {
		if (!state.ui) return;
		var w = state.ui.widgets;
		w.innerHTML = '';
		if (!state.loaded) {
			for (var i = 0; i < 4; i++) w.appendChild(skeleton('sb-dashboard-widget'));
			return;
		}
		w.appendChild(widget(_('Traffic'), [
			[ _('Uplink'),   prettyBytes(state.uRate) + '/s' ],
			[ _('Downlink'), prettyBytes(state.dRate) + '/s' ]
		]));
		w.appendChild(widget(_('Traffic Total'), [
			[ _('Uplink'),   prettyBytes(state.totUp) ],
			[ _('Downlink'), prettyBytes(state.totDown) ]
		]));
		w.appendChild(widget(_('System info'), [
			[ _('Active Connections'), '' + state.conns ],
			// Only when the API actually reports it — a "—" placeholder row is noise.
			state.memory ? [ _('Memory Usage'), prettyBytes(state.memory) ] : null
		]));
		w.appendChild(widget(_('Services info'), [
			[ 'sing-box', state.running ? '✔ ' + _('Running') : '✘ ' + _('Stopped'),
			  state.running ? 'sb-row-success' : 'sb-row-error' ],
			state.version ? [ _('Version'), state.version ] : null
		]));
	}

	function mountChrome() {
		var widgets = E('div', { 'class': 'sb-dashboard-widgets' });
		var groups  = E('div', { 'class': 'sb-dashboard-sections' });
		var sortBtn = E('button', { 'class': 'cbi-button cbi-button-neutral sb-sort-btn',
			'click': function () { setSortByLatency(!state.sortByLatency); } },
			_('Sort by latency'));
		var stopped = E('div', { 'class': 'sb-dashboard-stopped', 'role': 'status' },
			_('sing-box is stopped or its Clash API is unreachable. Start the service (and enable the API in General settings) to display the dashboard.'));
		var content = E('div', { 'class': 'sb-dashboard-content' }, [
			widgets,
			E('div', { 'class': 'sb-dashboard-toolbar' }, sortBtn),
			groups
		]);
		root.innerHTML = '';
		root.appendChild(stopped);
		root.appendChild(content);
		state.ui = { widgets: widgets, groups: groups, sortBtn: sortBtn, labels: {} };
	}

	function fact(key, value) {
		return E('div', { 'class': 'sb-dashboard-fact' }, [
			E('span', { 'class': 'sb-dashboard-fact-key' }, key),
			E('span', { 'class': 'sb-dashboard-fact-val' }, value)
		]);
	}
	function metaAction(label, url) {
		if (!/^https?:\/\/\S+$/i.test(url || '')) return null;
		return E('a', { 'class': 'cbi-button sb-dashboard-meta-action', 'href': url,
			'target': '_blank', 'rel': 'noopener noreferrer',
			'title': label, 'aria-label': label }, SbIcons.link());
	}

	// Normalize both shapes: today's sub_status ({title, userinfo:{…}}) and the
	// richer metadata block the subscription rework will add ({traffic:{…},
	// refillDate, webPageUrl, …}). Anything absent is simply not drawn.
	function subFacts(s) {
		var m = s.metadata || {};
		var u = s.userinfo || {};
		var t = m.traffic || null;
		var used  = t ? (+t.used || 0) : ((+u.upload || 0) + (+u.download || 0));
		var total = t ? (+t.total || 0) : (+u.total || 0);
		var unlimited = t ? (t.isUnlimited || !total) : !total;
		return {
			title: m.title || s.title || s.name,
			used: used, total: total, unlimited: unlimited,
			expire: fmtExpire(m.expire || u.expire),
			refill: fmtExpire(m.refillDate),
			announce: m.announce || '',
			webPageUrl: m.webPageUrl, supportUrl: m.supportUrl,
			announceUrl: m.announceUrl
		};
	}

	// DASH-3: the metadata strip is rendered for EVERY subscription (keyed by UCI
	// section name), including one that was never expanded into a proxy group
	// (sub_multi='0', the default) — otherwise its traffic cap / expiry would
	// never surface even though sub_status returns the userinfo.
	function subMetaStrip(name) {
		var s = state.subs[name];
		if (!s) return null;
		var f = subFacts(s);
		var facts = [
			fact(_('Nodes'),   '' + (s.node_count || 0)),
			fact(_('Updated'), agoText(s.last_update))
		];
		if (f.used || f.total)
			facts.push(fact(_('Traffic'), prettyBytes(f.used) + ' / ' +
				(f.unlimited ? '∞' : prettyBytes(f.total))));
		if (f.expire) facts.push(fact(_('Expires'), f.expire));
		if (f.refill) facts.push(fact(_('Refill'),  f.refill));

		var actions = [
			metaAction(_('Profile'), f.webPageUrl),
			metaAction(_('Support'), f.supportUrl),
			metaAction(_('More details'), f.announceUrl)
		].filter(Boolean);

		var kids = [
			E('div', { 'class': 'sb-dashboard-meta-heading' }, _('Subscription info:')),
			E('div', { 'class': 'sb-dashboard-meta-title' }, f.title),
			E('div', { 'class': 'sb-dashboard-facts' }, facts)
		];
		if (actions.length)
			kids.push(E('div', { 'class': 'sb-dashboard-meta-actions' }, actions));

		var box = [ E('div', { 'class': 'sb-dashboard-meta-main' }, kids) ];
		if (f.announce)
			box.push(E('blockquote', { 'class': 'sb-dashboard-meta-announce' }, f.announce));
		return E('div', { 'class': 'sb-dashboard-sub-meta', 'data-sub': name }, box);
	}

	function ingestConnections(data) {
		var conns = (data && data.connections) || [];
		state.conns = conns.length;
		// mihomo (and sing-box builds that follow it) put the process RSS here; when
		// the field is absent the widget simply omits the row.
		state.memory = (data && +data.memory) || 0;
		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		state.dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		state.uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;
		state.totDown = down; state.totUp = up;
	}

	// A node is a card, not a table row: display name (+ copy-link) on top,
	// protocol and latency on the footer line. Cards tile into the same grid as
	// the widgets, so a 100-node subscription reads as a wall of chips.
	function nodeCard(groupName, isSelector, member, proxies, currentNow) {
		var p = proxies[member] || {};
		var m = nodeMeta(member);
		var ms = memberDelay(p);
		var active = (member === currentNow);
		var switching = (state.switchingTag === member);
		var selectable = isSelector && !active && !switching && !state.switchingTag;
		var cls = 'sb-dashboard-node';
		if (active)     cls += ' sb-dashboard-node--active sb-dashboard-node-current';
		if (selectable) cls += ' sb-dashboard-node--selectable sb-dashboard-node-sel';
		if (isSelector && !selectable) cls += ' sb-dashboard-node--disabled';
		if (switching)  cls += ' sb-dashboard-node--switching';

		var attrs = { 'class': cls, 'data-group': groupName, 'data-name': member,
		              'title': member };
		if (selectable)
			attrs.click = ui.createHandlerFn(this, (function (g, mm) {
				return function () { return chooseNode(g, mm); };
			})(groupName, member));

		var head = [ E('b', { 'class': 'sb-dashboard-node-name' }, displayName(member)) ];
		// Country comes from the flag emoji the provider put in the node name
		// (backend: sharelink.country_from_flag_emoji); absent -> no badge.
		if (m.country)
			head.push(E('span', { 'class': 'sb-dashboard-node-country' }, m.country));
		if (m.link && COPYABLE_RE.test(m.link))
			head.push(E('button', { 'class': 'cbi-button sb-dashboard-node-copy',
				'title': _('Copy proxy link'), 'aria-label': _('Copy proxy link'),
				'click': (function (link) {
					return function (ev) {
						ev.stopPropagation();
						return copyLink(link);
					};
				})(m.link) }, SbIcons.copy()));

		var kids = [
			E('div', { 'class': 'sb-dashboard-node-head' }, head),
			E('div', { 'class': 'sb-dashboard-node-foot' }, [
				E('span', { 'class': 'sb-dashboard-node-type' }, m.type || p.type || ''),
				E('span', { 'class': 'sb-dashboard-lat ' + latClass(ms) }, latText(ms))
			])
		];
		var card = E('div', attrs, kids);
		if (switching) card.appendChild(SbIcons.snake());
		return card;
	}

	function sortMembers(members, proxies) {
		if (!state.sortByLatency) return members;
		return members.slice().sort(function (a, b) {
			var da = memberDelay(proxies[a]); var db = memberDelay(proxies[b]);
			var na = (da > 0) ? da : Infinity; var nb = (db > 0) ? db : Infinity;
			return na - nb;
		});
	}

	// Sections = proxy groups, plus every subscription that produced no group
	// (DASH-3) so its metadata strip still has a home.
	function sections() {
		var proxies = state.proxies || {};
		var out = Object.keys(proxies).filter(function (k) {
			return isGroupType(proxies[k].type) && (proxies[k].all || []).length;
		});
		Object.keys(state.subs || {}).sort().forEach(function (n) {
			if (!proxies[n]) out.push(n);
		});
		return out;
	}

	function sectionCard(gname) {
		var proxies = state.proxies || {};
		var grp = proxies[gname];
		var isSel = grp && (grp.type || '').toLowerCase() === 'selector';
		var busy  = !!state.testing[gname];
		var actions = [];

		if (grp)
			actions.push(E('span', { 'class': 'sb-dashboard-grp-type' },
				isSel ? _('selector') : _('auto')));

		// "Update subscriptions" only where a subscription actually feeds the
		// section — a hand-written selector has nothing to refresh.
		if (state.subs[gname]) {
			var upd = !!state.subUpdating[gname];
			var uattrs = { 'class': 'cbi-button cbi-button-action sb-dashboard-sub-update' +
				(upd ? ' busy' : ''),
				'click': ui.createHandlerFn(this, (function (n) {
					return function () { return updateSub(n); };
				})(gname)) };
			if (upd) uattrs.disabled = '';
			actions.push(E('button', uattrs, upd
				? [ SbIcons.loaderCircle(), E('span', {}, _('Update subscriptions')) ]
				: E('span', {}, _('Update subscriptions'))));
		}

		if (grp) {
			var label = E('span', { 'class': 'sb-dashboard-test-label' },
				testLabel(busy ? state.progress[gname] : null));
			state.ui.labels[gname] = label;
			var tattrs = { 'class': 'cbi-button cbi-button-action sb-dashboard-test' +
				(busy ? ' busy' : ''),
				'click': ui.createHandlerFn(this, (function (g) {
					return function () { return testGroup(g); };
				})(gname)) };
			if (busy) tattrs.disabled = '';
			actions.push(E('button', tattrs,
				busy ? [ SbIcons.loaderCircle(), label ] : label));
		}

		var grid = [];
		var strip = subMetaStrip(gname);
		if (strip) grid.push(strip);
		if (grp)
			sortMembers(grp.all || [], proxies).forEach(function (m) {
				grid.push(nodeCard(gname, isSel, m, proxies, grp.now));
			});

		return E('div', { 'class': 'sb-dashboard-group', 'data-group': gname }, [
			E('div', { 'class': 'sb-dashboard-grp-head' }, [
				E('div', { 'class': 'sb-dashboard-grp-name' }, gname),
				E('div', { 'class': 'sb-dashboard-grp-actions' }, actions)
			]),
			E('div', { 'class': 'sb-dashboard-grid' }, grid)
		]);
	}

	function renderGroups() {
		if (!state.ui) return;
		var box = state.ui.groups;
		box.innerHTML = '';
		state.ui.labels = {};
		if (!state.loaded) { box.appendChild(skeleton('sb-dashboard-group')); return; }
		var names = sections();
		if (!names.length) {
			box.appendChild(E('em', {}, _('No proxy groups. Configure selector/urltest outbounds.')));
			return;
		}
		names.forEach(function (gname) { box.appendChild(sectionCard(gname)); });
	}

	function repaint() {
		if (!state.ui) mountChrome();
		// The whole page collapses to a dashed plaque when the core is down — the
		// widgets and the (stale) node grid would only lie about live state.
		root.className = 'sb-dashboard' +
			((state.loaded && !state.running) ? ' sb-dashboard--stopped' : '');
		renderWidgets();
		renderGroups();
	}

	function poll() {
		var p = [
			callClashGet('/connections').then(function (res) {
				if (res && res.status === 'ok') {
					var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
					ingestConnections(d);
				}
			}, function () { /* core down: /version below flips the stopped plaque on */ }),
			callClashGet('/version').then(function (res) {
				if (res && res.status === 'ok') {
					var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
					state.version = (d && d.version) || '';
					state.running = true;
				}
			}, function () { state.running = false; })
		];
		state.proxiesEvery = (state.proxiesEvery + 1) % 3;
		if (state.proxiesEvery === 1) {
			p.push(fetchSubs());
			// Skip the /proxies refresh while a latency test is writing results
			// into state.proxies[*].history: fetchProxies replaces state.proxies
			// wholesale and would wipe them mid-run (button stuck "Testing…",
			// collected latencies flicker back to "N/A"). The next tick refreshes.
			// Also skip while a node switch is pending to preserve the optimistic
			// selection until refreshProxies completes (UIS-3).
			if (!anyTesting() && !state.switchPending) { p.push(fetchProxies()); p.push(fetchMeta()); }
		}
		return Promise.all(p).then(function () {
			state.loaded = true;   // first settled poll retires the skeletons
			repaint();
		}).catch(showUnreachable);
	}

	// SPA navigation away from this view never calls stop() (main.js only
	// stops on sub-tab clicks within the view), so the interval would poll
	// forever. The tick self-cancels once root leaves the DOM, and a pagehide
	// listener covers full-page teardown.
	function onPageHide() { stop(); }
	function start() {
		if (state.timer) return;
		poll();
		state.timer = setInterval(function () {
			if (root.isConnected === false) { stop(); return; }
			if (document.visibilityState === 'visible') poll();
		}, 2000);
		if (typeof window !== 'undefined' && window.addEventListener)
			window.addEventListener('pagehide', onPageHide);
	}
	function stop() {
		if (state.timer) { clearInterval(state.timer); state.timer = null; }
		if (typeof window !== 'undefined' && window.removeEventListener)
			window.removeEventListener('pagehide', onPageHide);
	}

	return { node: root, start: start, stop: stop, poll: poll,
	         refreshProxies: refreshProxies, refreshSubs: refreshSubs,
	         setSortByLatency: setSortByLatency };
}

return L.Class.extend({ buildDashboard: buildDashboard });
