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
		root.innerHTML = '';
		root.appendChild(widgets);
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

	// renderGroups() is defined in a later task; declared here so repaint() can
	// call it once it exists. Until then it is a no-op.
	function renderGroups() {}

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

	return { node: root, start: start, stop: stop, poll: poll };
}

return L.Class.extend({ buildDashboard: buildDashboard });
