'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

var callClashGet    = SbRpc.callClashGet;
var callClashMutate = SbRpc.callClashMutate;
var callDhcpLeases  = SbRpc.callDhcpLeases;

function buildMonitoring() {
	var state = {
		timer: null, searchTimer: null, prevConns: {}, closed: [], leases: {},
		filterDevice: 'all', search: '', tab: 'active',
		lastDown: null, lastUp: null, ui: null, conns: []
	};
	var root = E('div', { 'class': 'sb-monitoring' });

	// Per-keystroke repaint stalls the whole connection table on big lists
	// (spec C2.2.11). Buffer search input for 200 ms so the user can type
	// before the filter re-runs. searchTimer lives on `state` so stop() can
	// clear a pending debounce on teardown (spec S2-3) — otherwise the queued
	// repaint fires against a detached DOM.
	function debouncedSearch(value, cb) {
		if (state.searchTimer) clearTimeout(state.searchTimer);
		state.searchTimer = setTimeout(function () {
			state.searchTimer = null;
			cb(value);
		}, 200);
	}

	function fmtBytes(n) {
		n = n || 0; var u = ['B','KB','MB','GB','TB']; var i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return n.toFixed(i ? 1 : 0) + u[i];
	}
	function nameFor(ip) { return state.leases[ip] || ip; }

	function showUnreachable() {
		root.innerHTML = '';
		// The mounted chrome (state.ui) was just detached by innerHTML=''.
		// Drop the reference so the next successful poll re-mounts it via
		// repaint()'s `if (!state.ui) mountChrome()` guard (spec S2-4).
		state.ui = null;
		root.appendChild(E('em', {},
			_('Clash API unreachable — enable it in settings and restart.')));
	}
	function closeConn(id) {
		return callClashMutate('DELETE', '/connections/' + id, '')
			.then(poll).catch(showUnreachable);
	}
	function closeAll() {
		return callClashMutate('DELETE', '/connections', '')
			.then(poll).catch(showUnreachable);
	}

	// --- derived-data ingest (was the top half of the old repaint) ----------
	// poll() calls ingest(data) before repaint() so every handler reads the
	// CURRENT connection set via curConns() rather than a captured `data`
	// closure (spec S2-6). Lines kept verbatim from the old repaint head.
	function ingest(data) {
		var conns = (data && data.connections) || [];
		var nowIds = {}; conns.forEach(function (c) { if (c.id) nowIds[c.id] = c; });
		Object.keys(state.prevConns).forEach(function (id) {
			if (!nowIds[id]) state.closed.unshift(state.prevConns[id]);
		});
		if (state.closed.length > 100) state.closed.length = 100;
		state.prevConns = nowIds;

		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		state.dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		state.uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;
		state.conns = conns;
	}
	function curConns() { return state.conns || []; }

	// Simple per-connection search string. Task 9 (S2-9) replaces this body
	// with a precomputed/cached version; the signature stays the same.
	function searchHay(c) {
		var md = c.metadata || {};
		var host = md.host || md.destinationIP || '';
		var src  = md.sourceIP || '';
		var chain = (c.chains || []).join(' / ');
		return (host + ' ' + src + ' ' + nameFor(src) + ' ' + chain).toLowerCase();
	}

	// renderRows(conns) -> array of <tr>. Filter/map kept from the old
	// renderTable; the per-row Close button captures c.id by VALUE so a row
	// rebuilt from later data never acts on a stale connection (spec S2-6).
	function renderRows(conns) {
		var rows = conns.filter(function (c) {
			var src = (c.metadata && c.metadata.sourceIP) || '';
			if (state.filterDevice !== 'all' && src !== state.filterDevice) return false;
			if (state.search) {
				if (searchHay(c).indexOf(state.search.toLowerCase()) < 0) return false;
			}
			return true;
		}).map(function (c) {
			var md = c.metadata || {};
			var host = md.host || md.destinationIP || '?';
			var chain = (c.chains || []).join(' / ');
			return E('tr', {}, [
				E('td', {}, host + (md.destinationPort ? ':' + md.destinationPort : '')),
				E('td', {}, nameFor(md.sourceIP || '')),
				E('td', {}, chain || md.network || ''),
				E('td', {}, fmtBytes(c.download)),
				E('td', {}, fmtBytes(c.upload)),
				E('td', {}, c.id ? E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, (function (cid) {
						return function () { return closeConn(cid); };
					})(c.id))
				}, _('Close')) : '')
			]);
		});
		return rows.length ? rows
			: [ E('tr', {}, E('td', { 'colspan': 6 }, E('em', {}, _('No connections')))) ];
	}

	// Build the toolbar + table shell ONCE. The search <input>, device <select>,
	// count buttons, rate span, and tbody are stored on state.ui so subsequent
	// repaints update them in place — the <input> is never recreated, so focus
	// and caret survive the 1.5s poll (spec S2-4).
	function mountChrome() {
		var tbody = E('tbody', {});
		var table = E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, _('Host')), E('th', {}, _('Device')), E('th', {}, _('Chain')),
				E('th', {}, _('Down')), E('th', {}, _('Up')), E('th', {}, '')
			]),
			tbody
		]);
		var btnActive = E('button', { 'class': 'btn cbi-button',
			'click': function () { state.tab = 'active'; repaint(); } }, '');
		var btnClosed = E('button', { 'class': 'btn cbi-button',
			'click': function () { state.tab = 'closed'; repaint(); } }, '');
		var search = E('input', { 'type': 'search', 'placeholder': _('Search'),
			'value': state.search,
			'keyup': function (ev) {
				var v = ev.target.value;
				debouncedSearch(v, function (val) { state.search = val; updateRows(); });
			} });
		var deviceSel = E('select', {
			'change': function (ev) { state.filterDevice = ev.target.value; updateRows(); } }, []);
		var rateSpan = E('span', {}, '');
		var toolbar = E('div',
			{ 'style': 'display:flex;gap:1em;flex-wrap:wrap;align-items:center;margin:.5em 0' },
			[ btnActive, btnClosed, search, deviceSel,
			  E('button', { 'class': 'btn cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(this, function () { return closeAll(); }) },
				_('Close all')),
			  rateSpan ]);
		root.innerHTML = '';
		root.appendChild(toolbar);
		root.appendChild(table);
		state.ui = { tbody: tbody, btnActive: btnActive, btnClosed: btnClosed,
		             deviceSel: deviceSel, rateSpan: rateSpan };
	}

	// Rebuild the device <select>'s <option>s from the current connection set,
	// preserving the selected value. Cheap (a handful of options) and the
	// <select> element itself is reused, so it does not steal focus.
	function rebuildDeviceOptions() {
		if (!state.ui) return;
		var devices = {};
		curConns().forEach(function (c) {
			var s = c.metadata && c.metadata.sourceIP; if (s) devices[s] = true;
		});
		var sel = state.ui.deviceSel;
		sel.innerHTML = '';
		sel.appendChild(E('option', { 'value': 'all' }, _('All devices')));
		Object.keys(devices).forEach(function (ip) {
			var attr = { 'value': ip };
			if (state.filterDevice === ip) attr.selected = '';
			sel.appendChild(E('option', attr, nameFor(ip)));
		});
	}

	function updateRows() {
		if (!state.ui) return;
		var conns = state.tab === 'active' ? curConns() : state.closed;
		state.ui.tbody.innerHTML = '';
		renderRows(conns).forEach(function (tr) { state.ui.tbody.appendChild(tr); });
		state.ui.btnActive.textContent = _('Active') + ' ' + curConns().length;
		state.ui.btnClosed.textContent = _('Closed') + ' ' + state.closed.length;
	}

	function repaint() {
		if (!state.ui) mountChrome();
		rebuildDeviceOptions();
		state.ui.rateSpan.textContent =
			_('↓') + ' ' + fmtBytes(state.dRate || 0) + '/s  ' +
			_('↑') + ' ' + fmtBytes(state.uRate || 0) + '/s' +
			'  (' + _('total') + ' ↓' + fmtBytes(state.lastDown) +
			' ↑' + fmtBytes(state.lastUp) + ')';
		updateRows();
	}

	function poll() {
		return callClashGet('/connections').then(function (res) {
			if (!res || res.status !== 'ok') { showUnreachable(); return; }
			var data;
			try { data = JSON.parse(res.body); } catch (e) { data = { connections: [] }; }
			ingest(data);
			repaint();
		// A rejected RPC (ubus/network down) fires every 1.5s from the poll
		// interval; without .catch each one is an uncaught rejection (spec
		// S2-1). Surface it in the node and stop the rejection propagating.
		}).catch(showUnreachable);
	}

	// SPA navigation away from this view never calls stop() (main.js only
	// stops on sub-tab clicks within the view), so the interval would poll
	// forever (spec S2-2). The tick self-cancels once root leaves the DOM,
	// and a pagehide listener covers full-page teardown.
	function onPageHide() { stop(); }
	function start() {
		if (state.timer) return;
		callDhcpLeases().then(function (r) {
			var arr = (r && (r.dhcp_leases || r.leases)) || [];
			(Array.isArray(arr) ? arr : []).forEach(function (l) {
				if (l.ipaddr) state.leases[l.ipaddr] = l.hostname || l.ipaddr;
			});
		}).catch(function () {});
		poll();
		state.timer = setInterval(function () {
			if (root.isConnected === false) { stop(); return; }
			if (document.visibilityState === 'visible') poll();
		}, 1500);
		if (typeof window !== 'undefined' && window.addEventListener)
			window.addEventListener('pagehide', onPageHide);
	}
	function stop() {
		if (state.timer) { clearInterval(state.timer); state.timer = null; }
		if (state.searchTimer) { clearTimeout(state.searchTimer); state.searchTimer = null; }
		if (typeof window !== 'undefined' && window.removeEventListener)
			window.removeEventListener('pagehide', onPageHide);
	}

	// `poll`/`debouncedSearch` are exported for the regression harness
	// (tests/test_monitoring_js.sh); production callers use start()/stop().
	return { node: root, start: start, stop: stop, poll: poll, debouncedSearch: debouncedSearch };
}

return L.Class.extend({ buildMonitoring: buildMonitoring });
