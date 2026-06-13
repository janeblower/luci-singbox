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
		subs: {}, testing: {}
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
		});
	}
	function refreshProxies() { return fetchProxies().then(repaint); }

	function fetchSubs() {
		return callSubStatus().then(function (res) {
			var map = {};
			var arr = (res && res.subscriptions) || [];
			(Array.isArray(arr) ? arr : []).forEach(function (s) { map[s.name] = s; });
			state.subs = map;
		}, function () { /* keep last known */ });
	}
	function refreshSubs() { return fetchSubs().then(repaint); }

	function agoText(ts) {
		if (!ts) return _('never updated');
		var secs = Math.floor(Date.now() / 1000) - ts;
		if (secs < 0) secs = 0;
		if (secs < 60)   return _('updated %ds ago').format(secs);
		if (secs < 3600) return _('updated %dm ago').format(Math.floor(secs / 60));
		if (secs < 86400)return _('updated %dh ago').format(Math.floor(secs / 3600));
		return _('updated %dd ago').format(Math.floor(secs / 86400));
	}

	function updateSub(name) {
		return callRefresh('subscriptions', name).then(function () {
			return Promise.all([ fetchSubs(), fetchProxies() ]).then(repaint);
		}, function () {
			ui.addNotification(null, E('p', {}, _('Subscription update failed')));
		});
	}

	function setSortByLatency(on) { state.sortByLatency = !!on; repaint(); }
	function chooseNode(groupName, member) {
		// optimistic: reflect selection immediately, then resync from /proxies
		if (state.proxies[groupName]) state.proxies[groupName].now = member;
		renderGroups();
		return callClashMutate('PUT', '/proxies/' + groupName,
		                       JSON.stringify({ name: member }))
			.then(refreshProxies, function () {
				ui.addNotification(null, E('p', {}, _('Failed to switch node')));
				return refreshProxies();
			});
	}

	function testGroup(groupName) {
		var grp = state.proxies[groupName];
		if (!grp) return Promise.resolve();
		var members = (grp.all || []).filter(function (m) {
			var p = state.proxies[m];
			return p && !isGroupType(p.type);   // don't probe nested groups
		});
		return Promise.all(members.map(function (m) {
			return callClashDelay(m, '', '5000')
				.then(function (res) {
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
				})
				.then(renderGroups);
		}));
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
		return (p && p.history && p.history[0] && p.history[0].delay) || 0;
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
	function widget(title, body) {
		return E('div', { 'class': 'sb-dashboard-widget' }, [
			E('b', { 'class': 'sb-dashboard-widget-title' }, title),
			E('div', { 'class': 'sb-dashboard-widget-body' }, body)
		]);
	}

	function renderWidgets() {
		if (!state.ui) return;
		var w = state.ui.widgets;
		w.innerHTML = '';
		w.appendChild(widget(_('Speed'),
			'↓ ' + fmtBytes(state.dRate) + '/s  ↑ ' + fmtBytes(state.uRate) + '/s'));
		w.appendChild(widget(_('Total traffic'),
			'↓ ' + fmtBytes(state.totDown) + '  ↑ ' + fmtBytes(state.totUp)));
		w.appendChild(widget(_('Active connections'), '' + state.conns));
		w.appendChild(widget(_('sing-box'),
			(state.running ? _('running') : _('stopped')) +
			(state.version ? ('  ' + state.version) : '')));
	}

	function mountChrome() {
		var widgets = E('div', { 'class': 'sb-dashboard-widgets' });
		var groups  = E('div', { 'class': 'sb-dashboard-groups' });
		var sortBtn = E('button', { 'class': 'btn cbi-button sb-sort-btn',
			'click': function () { setSortByLatency(!state.sortByLatency); } },
			_('Sort by latency'));
		var toolbar = E('div', { 'class': 'sb-dashboard-toolbar' }, [ sortBtn ]);
		root.innerHTML = '';
		root.appendChild(widgets);
		root.appendChild(toolbar);
		root.appendChild(groups);
		state.ui = { widgets: widgets, groups: groups };
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

	function nodeRow(groupName, isSelector, member, proxies, currentNow) {
		var p = proxies[member] || {};
		var ms = memberDelay(p);
		var attrs = { 'class': 'sb-dashboard-node', 'data-group': groupName,
		              'data-name': member };
		if (member === currentNow) attrs['class'] += ' sb-dashboard-node-current';
		if (isSelector) {
			attrs['class'] += ' sb-dashboard-node-sel';
			attrs.click = ui.createHandlerFn(this, (function (g, m) {
				return function () { return chooseNode(g, m); };
			})(groupName, member));
		}
		return E('div', attrs, [
			E('span', { 'class': 'sb-dashboard-node-name' }, member),
			E('span', { 'class': 'sb-dashboard-node-type' }, p.type || ''),
			E('span', { 'class': 'sb-dashboard-lat ' + latClass(ms) }, latText(ms))
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
			var header = E('div', { 'class': 'sb-dashboard-grp-head' }, [
				E('b', {}, gname),
				E('span', { 'class': 'sb-dashboard-grp-type' },
					isSel ? _('selector') : _('auto')),
				E('button', { 'class': 'btn cbi-button sb-dashboard-test',
					'click': ui.createHandlerFn(this, (function (g) {
						return function () { return testGroup(g); };
					})(gname)) }, _('Test'))
			]);
			var subInfo = state.subs[gname];
			var children = [ header ];
			if (subInfo) {
				children.push(E('div', { 'class': 'sb-dashboard-sub' }, [
					E('span', {}, _('%d nodes').format(subInfo.node_count || 0)),
					E('span', {}, agoText(subInfo.last_update)),
					E('button', { 'class': 'btn cbi-button sb-dashboard-sub-update',
						'click': ui.createHandlerFn(this, (function (n) {
							return function () { return updateSub(n); };
						})(gname)) }, _('Update'))
				]));
			}
			var rows = members.map(function (m) {
				return nodeRow(gname, isSel, m, proxies, grp.now);
			});
			box.appendChild(E('div', { 'class': 'sb-dashboard-group', 'data-group': gname },
				children.concat(rows)));
		});
	}

	function repaint() {
		if (!state.ui) mountChrome();
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
		if (state.proxiesEvery === 1) { p.push(fetchProxies()); p.push(fetchSubs()); }
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
