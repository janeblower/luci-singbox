'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

var callClashGet    = SbRpc.callClashGet;
var callClashMutate = SbRpc.callClashMutate;
var callClashDelay  = SbRpc.callClashDelay;
var callSubStatus   = SbRpc.callSubStatus;
var callRefresh     = SbRpc.callRefresh;

function buildDashboard() {
	var state = {
		timer: null, ui: null,
		lastDown: null, lastUp: null, dRate: 0, uRate: 0,
		totDown: 0, totUp: 0, conns: 0, version: '', running: false,
		proxies: {}, proxiesEvery: 0, sortByLatency: false,
		subs: {}, subsNow: 0,
		// DASH-1/DASH-4: per-group "latency test in progress" flag. Set while a
		// group's probes run so renderGroups() can disable its Test button and
		// repeated clicks don't stack concurrent probe storms.
		testing: {},
		// UIS-3: flag to suppress periodic fetchProxies while a node switch is
		// pending (between chooseNode's PUT and refreshProxies), preventing the
		// poll from wiping the optimistic selection mid-flight.
		switchPending: false
	};
	var root = E('div', { 'class': 'sb-dashboard' });

	function fmtBytes(n) {
		n = n || 0; var u = ['B','KB','MB','GB','TB']; var i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return n.toFixed(i ? 1 : 0) + u[i];
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
	function refreshProxies() { return fetchProxies().then(repaint); }
	// True while any group's latency test is mid-run. The background poll uses
	// this to avoid replacing state.proxies (which would wipe in-flight results).
	function anyTesting() {
		for (var k in state.testing) if (state.testing[k]) return true;
		return false;
	}

	function fetchSubs() {
		return callSubStatus().then(function (res) {
			var map = {};
			var arr = (res && res.subscriptions) || [];
			(Array.isArray(arr) ? arr : []).forEach(function (s) { map[s.name] = s; });
			state.subs = map;
			// DASH-2: prefer the server-supplied `now` (like the status panel)
			// so "updated X ago" stays accurate on routers whose clock drifts
			// from the browser (common without NTP). Falls back to the client
			// clock in agoText() when the backend doesn't emit `now`.
			state.subsNow = (res && +res.now) || 0;
		}, function () { /* keep last known */ });
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
		return callRefresh('subscriptions', name).then(function () {
			return Promise.all([ fetchSubs(), fetchProxies() ]).then(repaint);
		}, function () {
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
		renderGroups();
		return callClashMutate('PUT', '/proxies/' + groupName,
		                       JSON.stringify({ name: member }))
			.then(refreshProxies, function () {
				ui.addNotification(null, E('p', {}, _('Failed to switch node')));
				return refreshProxies();
			})
			// Clear on BOTH settle paths: a stuck switchPending freezes the panel on a
			// stale value forever, because poll() then refuses to refetch the groups.
			.then(function () { state.switchPending = false; },
			      function () { state.switchPending = false; });
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
		renderGroups();   // reflect the disabled/busy Test button immediately

		var idx = 0;
		function probeOne(m) {
			return callClashDelay(m, '', '5000').then(function (res) {
				var ms = 0;
				if (res && res.status === 'ok') {
					var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
					ms = (d && d.delay) || 0;
				}
				var p = state.proxies[m];
				if (p) p.history = [ { delay: ms } ];
			}, function () {
				var p = state.proxies[m];
				if (p) p.history = [ { delay: 0 } ];
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
		return worker().then(function () {
			state.testing[groupName] = false;
			renderGroups();
		}, function () {
			state.testing[groupName] = false;
			renderGroups();
		});
	}

	function latClass(ms) {
		if (!(ms > 0)) return 'sb-lat-none';
		if (ms < 300) return 'sb-lat-good';
		if (ms < 800) return 'sb-lat-mid';
		return 'sb-lat-bad';
	}
	function latText(ms) { return (ms > 0) ? (ms + 'ms') : '—'; }
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

	function showUnreachable() {
		root.innerHTML = '';
		// The mounted chrome (state.ui) was just detached by innerHTML=''.
		// Drop the reference so the next successful poll re-mounts it via
		// repaint()'s `if (!state.ui) mountChrome()` guard.
		state.ui = null;
		root.appendChild(E('em', { 'class': 'sb-dashboard-unavailable' },
			_('Clash API unreachable — enable it in General settings and restart the service.')));
	}

	// --- widgets -----------------------------------------------------------
	// A widget is a bordered card: bold title, then `key: value` rows. `cls` on a
	// row tints its value via --success/--error, so "stopped" reads red without
	// a second colour system.
	function widget(title, rows) {
		return E('div', { 'class': 'sb-dashboard-widget' }, [
			E('b', { 'class': 'sb-dashboard-widget-title' }, title),
			E('div', { 'class': 'sb-dashboard-widget-rows' },
				rows.map(function (r) {
					return E('div', { 'class': 'sb-dashboard-widget-row ' + (r[2] || '') }, [
						E('span', { 'class': 'sb-dashboard-widget-key' }, r[0] + ': '),
						E('span', { 'class': 'sb-dashboard-widget-val' }, r[1])
					]);
				}))
		]);
	}

	function renderWidgets() {
		if (!state.ui) return;
		var w = state.ui.widgets;
		w.innerHTML = '';
		w.appendChild(widget(_('Speed'), [
			[ _('Download'), fmtBytes(state.dRate) + '/s' ],
			[ _('Upload'),   fmtBytes(state.uRate) + '/s' ]
		]));
		w.appendChild(widget(_('Total traffic'), [
			[ _('Downloaded'), fmtBytes(state.totDown) ],
			[ _('Uploaded'),   fmtBytes(state.totUp) ]
		]));
		w.appendChild(widget(_('Connections'), [
			[ _('Active'), '' + state.conns ]
		]));
		w.appendChild(widget(_('sing-box'), [
			[ _('Status'), state.running ? _('running') : _('stopped'),
			  state.running ? 'ok' : 'err' ],
			[ _('Version'), state.version || '—' ]
		]));
	}

	function mountChrome() {
		var widgets = E('div', { 'class': 'sb-dashboard-widgets' });
		var subs    = E('div', { 'class': 'sb-dashboard-subs' });
		var groups  = E('div', { 'class': 'sb-dashboard-groups' });
		var sortBtn = E('button', { 'class': 'cbi-button cbi-button-neutral sb-sort-btn',
			'click': function () { setSortByLatency(!state.sortByLatency); } },
			_('Sort by latency'));
		root.innerHTML = '';
		root.appendChild(widgets);
		root.appendChild(subs);
		root.appendChild(E('div', { 'class': 'sb-dashboard-toolbar' }, sortBtn));
		root.appendChild(groups);
		state.ui = { widgets: widgets, subs: subs, groups: groups, sortBtn: sortBtn };
	}

	function fact(key, value) {
		return E('div', { 'class': 'sb-dashboard-fact' }, [
			E('span', { 'class': 'sb-dashboard-fact-key' }, key),
			E('span', { 'class': 'sb-dashboard-fact-val' }, value)
		]);
	}

	// DASH-3: render every subscription (keyed by UCI section name) as a strip,
	// independent of whether it was expanded into a proxy group. A non-expanded
	// subscription (sub_multi='0', the default) produces no clash-api group, so
	// its traffic cap / expiry would otherwise never surface — even though
	// sub_status returns the userinfo.
	//
	// A strip, not a table row: the columns were the only reason this file had to
	// fight the themes over how they lay out LuCI's div-table, and a plan's facts
	// (nodes / updated / traffic / expiry) are label-value pairs, not a matrix.
	function renderSubscriptions() {
		if (!state.ui) return;
		var box = state.ui.subs;
		box.innerHTML = '';
		var names = Object.keys(state.subs || {}).sort();
		// Nothing to show -> the whole block collapses, no empty heading left over.
		box.style.display = names.length ? '' : 'none';
		if (!names.length) return;

		names.forEach(function (name) {
			var s = state.subs[name] || {};
			var ui_ = s.userinfo || {};
			var used  = (+ui_.upload || 0) + (+ui_.download || 0);
			var total = +ui_.total || 0;
			// Native LuCI progressbar (as on the Overview page) instead of a
			// hand-rolled "12MB / 30GB" span.
			var traffic = total
				? E('div', { 'class': 'cbi-progressbar',
				             'title': fmtBytes(used) + ' / ' + fmtBytes(total) },
					E('div', { 'style': 'width:' +
						Math.min(100, Math.round(used / total * 100)) + '%' }))
				: (used ? fmtBytes(used) : '—');
			box.appendChild(E('div', { 'class': 'sb-dashboard-sub', 'data-sub': name }, [
				E('b', { 'class': 'sb-dashboard-sub-name' }, s.title || name),
				E('div', { 'class': 'sb-dashboard-facts' }, [
					fact(_('Nodes'),   '' + (s.node_count || 0)),
					fact(_('Updated'), agoText(s.last_update)),
					fact(_('Traffic'), traffic),
					fact(_('Expires'), fmtExpire(ui_.expire) || '—')
				]),
				E('button', { 'class': 'cbi-button cbi-button-action sb-dashboard-sub-update',
					'click': ui.createHandlerFn(this, (function (n) {
						return function () { return updateSub(n); };
					})(name)) }, _('Update'))
			]));
		});
	}

	function ingestConnections(data) {
		var conns = (data && data.connections) || [];
		state.conns = conns.length;
		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		state.dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		state.uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;
		state.totDown = down; state.totUp = up;
	}

	// A node is a card, not a table row: name on top, protocol and latency on the
	// footer line. Cards tile into the same responsive grid as the widgets, so a
	// 100-node subscription reads as a wall of chips instead of a 100-row scroll.
	function nodeRow(groupName, isSelector, member, proxies, currentNow) {
		var p = proxies[member] || {};
		var ms = memberDelay(p);
		var attrs = { 'class': 'sb-dashboard-node', 'data-group': groupName,
		              'data-name': member, 'title': member };
		if (member === currentNow) attrs['class'] += ' sb-dashboard-node-current';
		if (isSelector) {
			attrs['class'] += ' sb-dashboard-node-sel';
			attrs.click = ui.createHandlerFn(this, (function (g, m) {
				return function () { return chooseNode(g, m); };
			})(groupName, member));
		}
		return E('div', attrs, [
			E('div', { 'class': 'sb-dashboard-node-head' },
				E('b', { 'class': 'sb-dashboard-node-name' }, member)),
			E('div', { 'class': 'sb-dashboard-node-foot' }, [
				E('span', { 'class': 'sb-dashboard-node-type' }, p.type || ''),
				E('span', { 'class': 'sb-dashboard-lat ' + latClass(ms) }, latText(ms))
			])
		]);
	}

	function sortMembers(members, proxies) {
		if (!state.sortByLatency) return members;
		return members.slice().sort(function (a, b) {
			var da = memberDelay(proxies[a]); var db = memberDelay(proxies[b]);
			var na = (da > 0) ? da : Infinity; var nb = (db > 0) ? db : Infinity;
			return na - nb;
		});
	}

	function renderGroups() {
		if (!state.ui) return;
		var proxies = state.proxies || {};
		var box = state.ui.groups;
		box.innerHTML = '';
		var names = Object.keys(proxies).filter(function (k) {
			return isGroupType(proxies[k].type) && (proxies[k].all || []).length;
		});
		if (!names.length) {
			box.appendChild(E('em', {}, _('No proxy groups. Configure selector/urltest outbounds.')));
			return;
		}
		names.forEach(function (gname) {
			var grp = proxies[gname];
			var isSel = (grp.type || '').toLowerCase() === 'selector';
			var members = sortMembers(grp.all || [], proxies);
			var busy = !!state.testing[gname];
			var testBtnAttrs = {
				'class': 'cbi-button cbi-button-action sb-dashboard-test' + (busy ? ' busy' : ''),
				'click': ui.createHandlerFn(this, (function (g) {
					return function () { return testGroup(g); };
				})(gname))
			};
			if (busy) testBtnAttrs.disabled = '';
			var header = E('div', { 'class': 'sb-dashboard-grp-head' }, [
				E('div', { 'class': 'sb-dashboard-grp-name' }, gname),
				E('div', { 'class': 'sb-dashboard-grp-actions' }, [
					E('span', { 'class': 'sb-dashboard-grp-type' },
						isSel ? _('selector') : _('auto')),
					E('button', testBtnAttrs, busy ? _('Testing…') : _('Test'))
				])
			]);
			var rows = members.map(function (m) {
				return nodeRow(gname, isSel, m, proxies, grp.now);
			});
			box.appendChild(E('div', { 'class': 'sb-dashboard-group', 'data-group': gname },
				[ header, E('div', { 'class': 'sb-dashboard-nodes' }, rows) ]));
		});
	}

	function repaint() {
		if (!state.ui) mountChrome();
		renderWidgets();
		renderSubscriptions();
		renderGroups();
	}

	function poll() {
		var p = [
			callClashGet('/connections').then(function (res) {
				if (res && res.status === 'ok') {
					var d; try { d = JSON.parse(res.body); } catch (e) { d = {}; }
					ingestConnections(d);
				}
			}),
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
			// collected latencies flicker back to "—"). The next tick refreshes.
			// Also skip while a node switch is pending to preserve the optimistic
			// selection until refreshProxies completes (UIS-3).
			if (!anyTesting() && !state.switchPending) p.push(fetchProxies());
		}
		return Promise.all(p).then(repaint).catch(showUnreachable);
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
