'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

var callClashGet    = SbRpc.callClashGet;
var callClashMutate = SbRpc.callClashMutate;
var callDhcpLeases  = SbRpc.callDhcpLeases;

// A closed connection is history: it can never come back, so the list only ever
// grows. Cap it (forkop caps at the same number) — an hour of browsing on a
// busy LAN otherwise accumulates tens of thousands of rows and the repaint,
// which rebuilds the whole tbody, starts dropping frames.
var CLOSED_LIMIT = 300;

function buildMonitoring() {
	var state = {
		timer: null, searchTimer: null, leases: {},
		active: {}, closed: {}, closing: {},
		filterDevice: 'all', search: '', tab: 'active',
		paused: false, pausedAt: 0,
		lastDown: null, lastUp: null, dRate: 0, uRate: 0, totDown: 0, totUp: 0,
		ui: null
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
	function pad2(n) { return (n < 10 ? '0' : '') + n; }
	function fmtDuration(ms) {
		var s = Math.max(0, Math.floor(ms / 1000));
		var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60);
		return (h > 0 ? (h + ':' + pad2(m)) : ('' + m)) + ':' + pad2(s % 60);
	}
	function startedAt(c) {
		var t = Date.parse(c.start || '');
		return isFinite(t) ? t : (c._seenAt || Date.now());
	}
	// While paused the clock is frozen at pausedAt, so the durations the user is
	// reading stay put instead of ticking under the cursor.
	function durationOf(c) {
		var end = c.closedAt || (state.paused ? state.pausedAt : Date.now());
		return fmtDuration(end - startedAt(c));
	}
	function nameFor(ip) { return state.leases[ip] || ip; }

	// The default HTTPS port is noise on every single row; the host alone is the
	// information. Any other port is meaningful, so it stays.
	function endpoint(c) {
		var md = c.metadata || {};
		var host = md.host || md.destinationIP || '';
		if (!host) return '';
		var port = md.destinationPort ? String(md.destinationPort) : '';
		if (!port || port === '443') return host;
		if (host.indexOf(':') >= 0 && host.charAt(0) !== '[') return '[' + host + ']:' + port;
		return host + ':' + port;
	}
	// clash orders `chains` innermost-first, so the LAST element is the group or
	// rule the traffic was routed by — that is the "route", not the leaf node.
	// `rule` is the fallback when the chain is a bare direct outbound.
	function routeOf(c) {
		var ch = (c.chains || []);
		return ch.length ? ch[ch.length - 1] : (c.rule || '');
	}
	function networkOf(c) {
		return ((c.metadata && c.metadata.network) || '').toLowerCase();
	}
	function sourceOf(c) {
		var ip = (c.metadata && c.metadata.sourceIP) || '';
		return { ip: ip, name: nameFor(ip) };
	}

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
		// A per-connection DELETE failing does NOT mean the Clash API is down —
		// the connection may simply have closed between repaint and click (audit
		// 9.1). Re-poll to resync the view instead of wiping the whole table with
		// showUnreachable(); only a rejected poll RPC (real ubus/API failure)
		// clears the table, via poll()'s own .catch(showUnreachable).
		state.closing[id] = true;
		repaint();
		function done() { delete state.closing[id]; return poll(); }
		return callClashMutate('DELETE', '/connections/' + id, '').then(done, done);
	}
	function closeAll() {
		// Symmetric with closeConn() (audit 9.1 / MON-1): a failing bulk DELETE
		// — e.g. a benign "nothing to close" / transient non-fatal response —
		// must re-poll to resync, NOT wipe the whole table with showUnreachable.
		return callClashMutate('DELETE', '/connections', '').then(poll, poll);
	}

	// --- derived-data ingest (was the top half of the old repaint) ----------
	// poll() calls ingest(data) before repaint() so every handler reads the
	// CURRENT connection set rather than a captured `data` closure (spec S2-6).
	function ingest(data) {
		var list = (data && data.connections) || [];
		var now = Date.now();
		var seen = {};
		list.forEach(function (c) {
			if (!c.id) return;
			seen[c.id] = true;
			c._seenAt = now;
			state.active[c.id] = c;
		});
		// MON-2: a connection's close is detected one poll AFTER its last
		// appearance, so the archived Down/Up figures are the LAST-OBSERVED
		// sample. Accurate to within one poll interval; the Closed tab is a
		// historical view, not a ledger.
		Object.keys(state.active).forEach(function (id) {
			if (seen[id]) return;
			var c = state.active[id];
			c.closedAt = now;
			delete state.active[id];
			delete state.closing[id];
			state.closed[id] = c;
		});
		var ids = Object.keys(state.closed);
		if (ids.length > CLOSED_LIMIT) {
			ids.sort(function (a, b) {
				return (state.closed[a].closedAt || 0) - (state.closed[b].closedAt || 0);
			}).slice(0, ids.length - CLOSED_LIMIT).forEach(function (id) {
				delete state.closed[id];
			});
		}

		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		state.dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		state.uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;
		state.totDown = down; state.totUp = up;
	}
	function activeConns() {
		return Object.keys(state.active).map(function (id) { return state.active[id]; })
			.sort(function (a, b) { return startedAt(b) - startedAt(a); });
	}
	function closedConns() {
		return Object.keys(state.closed).map(function (id) { return state.closed[id]; })
			.sort(function (a, b) { return (b.closedAt || 0) - (a.closedAt || 0); });
	}
	function shownConns() {
		return (state.tab === 'active') ? activeConns() : closedConns();
	}

	// Precomputed, lowercased, MEMOIZED search string per connection (spec
	// S2-9). Built once from the fields the user actually searches, instead of
	// JSON.stringify(c) on every keystroke (which also matched JSON key names).
	function searchHay(c) {
		if (c._sbHay != null) return c._sbHay;
		var src = sourceOf(c);
		c._sbHay = [ endpoint(c), src.ip, src.name, routeOf(c), networkOf(c),
		             (c.chains || []).join(' ') ].join(' ').toLowerCase();
		return c._sbHay;
	}

	function visibleConns() {
		return shownConns().filter(function (c) {
			var src = (c.metadata && c.metadata.sourceIP) || '';
			if (state.filterDevice !== 'all' && src !== state.filterDevice) return false;
			if (state.search && searchHay(c).indexOf(state.search.toLowerCase()) < 0)
				return false;
			return true;
		});
	}

	// data-label is what turns the table into a stacked card list on a phone:
	// style.css hides the <thead> under 720px and prints the label before each
	// cell's value instead.
	function td(label, content, cls) {
		return E('td', { 'data-label': label, 'class': cls || '' }, content);
	}
	function val(text, cls) {
		var t = text || '—';
		return E('span', { 'class': 'sb-mon-val ' + (cls || ''), 'title': t }, t);
	}

	function renderRow(c) {
		var active = state.tab === 'active';
		var src = sourceOf(c);
		var closing = !!state.closing[c.id];
		return E('tr', { 'class': (active ? '' : 'closed') + (closing ? ' closing' : '') }, [
			td(_('Host'),  val(endpoint(c))),
			td(_('Type'),  val(networkOf(c), 'sb-mon-net')),
			td(_('Route'), val(routeOf(c), 'sb-mon-route')),
			td(_('Time'),  val(durationOf(c))),
			td(_('Down'),  val(fmtBytes(c.download))),
			td(_('Up'),    val(fmtBytes(c.upload))),
			td(_('Source'), E('span', { 'class': 'sb-mon-src', 'title': src.name + ' ' + src.ip }, [
				E('span', { 'class': 'sb-mon-src-name' }, src.name || '—'),
				(src.name !== src.ip)
					? E('span', { 'class': 'sb-mon-src-ip' }, src.ip) : ''
			])),
			// Closed connections are already terminated, so they get no Close
			// button — clicking it would DELETE a non-existent id (audit 9.1).
			td('', (active && c.id) ? E('button', {
				'class': 'btn cbi-button cbi-button-remove sb-mon-row-close',
				'data-action': 'close-row',
				'title': _('Close connection'),
				'aria-label': _('Close connection'),
				'disabled': closing ? '' : null,
				// c.id is captured BY VALUE, so a row rebuilt from later data
				// never acts on a stale connection (spec S2-6).
				'click': ui.createHandlerFn(this, (function (cid) {
					return function () { return closeConn(cid); };
				})(c.id))
			}, '✕') : '', 'sb-mon-action')
		]);
	}

	// Build the toolbar + table shell ONCE. The search <input>, device <select>,
	// count buttons, rate span and tbody are stored on state.ui so subsequent
	// repaints update them in place — the <input> is never recreated, so focus
	// and caret survive the poll (spec S2-4).
	function mountChrome() {
		var tbody = E('tbody', {});
		var table = E('table', { 'class': 'table cbi-section-table sb-mon-table' }, [
			E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, _('Host')), E('th', {}, _('Type')), E('th', {}, _('Route')),
				E('th', {}, _('Time')), E('th', {}, '↓ ' + _('Down')),
				E('th', {}, '↑ ' + _('Up')), E('th', {}, _('Source')), E('th', {}, '')
			])),
			tbody
		]);
		var btnActive = E('button', { 'class': 'btn cbi-button sb-mon-tab',
			'click': function () { state.tab = 'active'; repaint(); } }, '');
		var btnClosed = E('button', { 'class': 'btn cbi-button sb-mon-tab',
			'click': function () { state.tab = 'closed'; repaint(); } }, '');
		var search = E('input', { 'type': 'search', 'placeholder': _('Search'),
			'class': 'cbi-input-text sb-mon-search', 'value': state.search,
			'keyup': function (ev) {
				var v = ev.target.value;
				debouncedSearch(v, function (val_) { state.search = val_; repaint(); });
			} });
		var deviceSel = E('select', { 'class': 'cbi-input-select sb-mon-device',
			'change': function (ev) { state.filterDevice = ev.target.value; repaint(); } }, []);
		var btnCloseAll = E('button', {
			'class': 'btn cbi-button cbi-button-remove sb-mon-icon',
			'data-action': 'close-all',
			'title': _('Close all connections'), 'aria-label': _('Close all connections'),
			'click': ui.createHandlerFn(this, function () { return closeAll(); })
		}, '✕');
		var btnPause = E('button', { 'class': 'btn cbi-button sb-mon-icon',
			'data-action': 'pause',
			'click': function () { setPaused(!state.paused); } }, '');
		var rateSpan = E('span', { 'class': 'sb-mon-rate' }, '');
		var toolbar = E('div', { 'class': 'sb-mon-toolbar' }, [
			E('div', { 'class': 'sb-mon-tabs' }, [ btnActive, btnClosed ]),
			E('div', { 'class': 'sb-mon-filters' }, [ deviceSel, search ]),
			E('div', { 'class': 'sb-mon-actions' }, [ rateSpan, btnCloseAll, btnPause ])
		]);
		root.innerHTML = '';
		root.appendChild(toolbar);
		root.appendChild(E('div', { 'class': 'sb-mon-table-wrap' }, table));
		state.ui = { tbody: tbody, btnActive: btnActive, btnClosed: btnClosed,
		             deviceSel: deviceSel, rateSpan: rateSpan,
		             btnCloseAll: btnCloseAll, btnPause: btnPause };
	}

	function setPaused(on) {
		state.paused = !!on;
		state.pausedAt = state.paused ? Date.now() : 0;
		repaint();
	}

	// Rebuild the device <select>'s <option>s from the current connection set,
	// preserving the selected value. The <select> element itself is reused, so
	// it does not steal focus.
	function rebuildDeviceOptions() {
		var devices = {};
		// Drive this off the set actually being DISPLAYED, not the live one: on
		// the Closed tab, devices whose connections have all closed would
		// otherwise vanish from the dropdown and become unfilterable (audit 9.2+).
		shownConns().forEach(function (c) {
			var s = c.metadata && c.metadata.sourceIP; if (s) devices[s] = true;
		});
		// If the device we filter on has vanished from the current set, no
		// <option> would be emitted for it, so the <select> would silently fall
		// back to "All" while the filter still held the stale IP — stranding the
		// user at zero rows with a dropdown that disagrees (audit 9.2).
		if (state.filterDevice !== 'all' && !devices[state.filterDevice])
			state.filterDevice = 'all';
		var sel = state.ui.deviceSel;
		sel.innerHTML = '';
		sel.appendChild(E('option', { 'value': 'all' }, _('All devices')));
		Object.keys(devices).sort().forEach(function (ip) {
			var attr = { 'value': ip };
			if (state.filterDevice === ip) attr.selected = '';
			sel.appendChild(E('option', attr, nameFor(ip)));
		});
	}

	// A repaint blows the tbody away, which kills any text the user is in the
	// middle of selecting (to copy a host out of the table). Hold the repaint
	// while a selection is live inside our root; the next poll paints it.
	function hasSelectionInside() {
		if (typeof window === 'undefined' || !window.getSelection) return false;
		var s = window.getSelection();
		if (!s || s.isCollapsed) return false;
		return (s.anchorNode && root.contains && root.contains(s.anchorNode)) ||
		       (s.focusNode  && root.contains && root.contains(s.focusNode));
	}

	function repaint() {
		if (!state.ui) mountChrome();
		if (hasSelectionInside()) return;
		var u = state.ui;
		var active = state.tab === 'active';
		var nActive = Object.keys(state.active).length;
		var nClosed = Object.keys(state.closed).length;

		rebuildDeviceOptions();
		u.tbody.innerHTML = '';
		var rows = visibleConns();
		if (rows.length)
			rows.forEach(function (c) { u.tbody.appendChild(renderRow(c)); });
		else
			u.tbody.appendChild(E('tr', {}, E('td', { 'colspan': 8 },
				E('em', {}, _('No connections')))));

		u.btnActive.textContent = _('Active') + ' ' + nActive;
		u.btnClosed.textContent = _('Closed') + ' ' + nClosed;
		// cbi-button-active is LuCI's themed selected-button class (audit 9.6).
		u.btnActive.className = 'btn cbi-button sb-mon-tab' + (active ? ' cbi-button-active' : '');
		u.btnClosed.className = 'btn cbi-button sb-mon-tab' + (active ? '' : ' cbi-button-active');
		u.btnCloseAll.disabled = (nActive === 0);
		// Geometric Shapes (U+25A0..U+25FF) only: U+23F8 PAUSE renders as tofu in
		// the stock OpenWrt font stack, which is how the button shipped as an
		// empty box the first time round.
		u.btnPause.textContent = state.paused ? '▶' : '▮▮';
		u.btnPause.title = state.paused ? _('Resume updates') : _('Pause updates');
		u.btnPause.className = 'btn cbi-button sb-mon-icon' +
			(state.paused ? ' cbi-button-active' : '');
		u.rateSpan.textContent =
			'↓ ' + fmtBytes(state.dRate) + '/s  ↑ ' + fmtBytes(state.uRate) + '/s' +
			'  (' + fmtBytes(state.totDown) + ' / ' + fmtBytes(state.totUp) + ')';
	}

	function poll() {
		// Paused means paused: no ingest, no repaint, the table the user is
		// reading stays exactly as it was.
		if (state.paused) return Promise.resolve();
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

	// `poll`/`debouncedSearch`/`_searchHay`/`setPaused` are exported for the
	// regression harness (tests/ui/test_monitoring_js.test.ts); production
	// callers use start()/stop().
	return { node: root, start: start, stop: stop, poll: poll,
	         setPaused: setPaused,
	         debouncedSearch: debouncedSearch, _searchHay: searchHay };
}

return L.Class.extend({ buildMonitoring: buildMonitoring });
