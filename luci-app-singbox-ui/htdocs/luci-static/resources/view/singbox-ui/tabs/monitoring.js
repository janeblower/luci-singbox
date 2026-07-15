'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.icons as SbIcons';
'require view.singbox-ui.lib.common as SbCommon';

var callClashGet     = SbRpc.callClashGet;
var callClashMutate  = SbRpc.callClashMutate;
var callDhcpLeases   = SbRpc.callDhcpLeases;
var callOutboundMeta = SbRpc.callOutboundMeta;

// A closed connection is history: it can never come back, so the list only ever
// grows. Cap it (forkop caps at the same number) — an hour of browsing on a
// busy LAN otherwise accumulates tens of thousands of rows and the repaint,
// which rebuilds the whole tbody, starts dropping frames.
var CLOSED_LIMIT = 300;
// One interval drives everything: the duration column must tick every 500ms
// (otherwise the times sit frozen between polls), the connection feed only
// needs re-reading every 1500ms. Two timers for one view is one timer too many.
var TICK_MS = 500;
var POLL_EVERY_TICKS = 3;

function buildMonitoring() {
	var state = {
		timer: null, tick: 0, searchTimer: null, leases: {}, names: {},
		active: {}, closed: {}, closing: {},
		filterDevice: 'all', search: '', tab: 'active',
		paused: false, pausedAt: 0, pending: null,
		loading: true, failed: false,
		timeCells: [], ui: null
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

	var fmtBytes = SbCommon.prettyBytes;
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
	// Our outbound tags are either a UCI section name (readable already) or a
	// content hash for a subscription node (`<sub>__<hash>`, unreadable). The
	// rpcd `outbound_meta` side-car maps tag -> { name } for exactly that case;
	// dashboard.js reads the same map. Anything not in it (e.g. the implicit
	// `direct` outbound) is shown raw — the tag IS the name there.
	function routeName(tag) {
		var m = state.names[tag];
		return (m && m.name) || tag || '';
	}
	// clash orders `chains` innermost-first, so the LAST element is the group or
	// rule the traffic was routed by — that is the "route", not the leaf node.
	// `rule` is the fallback when the chain is a bare direct outbound.
	function routeOf(c) {
		var ch = (c.chains || []);
		return routeName(ch.length ? ch[ch.length - 1] : (c.rule || ''));
	}
	function networkOf(c) {
		return ((c.metadata && c.metadata.network) || '').toLowerCase();
	}
	function sourceOf(c) {
		var ip = (c.metadata && c.metadata.sourceIP) || '';
		return { ip: ip, name: nameFor(ip) };
	}

	function closeConn(id) {
		// A per-connection DELETE failing does NOT mean the Clash API is down —
		// the connection may simply have closed between repaint and click (audit
		// 9.1). Re-poll to resync the view instead of wiping the whole table;
		// only a rejected poll RPC (real ubus/API failure) marks the view failed.
		state.closing[id] = true;
		repaint();
		function done() { delete state.closing[id]; return poll(); }
		return callClashMutate('DELETE', '/connections/' + id, '').then(done, done);
	}
	function closeAll() {
		// Symmetric with closeConn() (audit 9.1 / MON-1): a failing bulk DELETE
		// — e.g. a benign "nothing to close" / transient non-fatal response —
		// must re-poll to resync, NOT wipe the whole table.
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
			delete state.closed[c.id];
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
		state.loading = false;
		state.failed = false;
	}

	// Pausing must not LOSE data: a connection that opened and closed while the
	// view was frozen would otherwise never be seen at all. Park the newest
	// payload (only the newest — the older ones are already superseded) and
	// apply it on resume, exactly like forkop's pendingConnectionsPayload.
	function applyPayload(data) {
		if (state.paused) { state.pending = data; return; }
		ingest(data);
		repaint();
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
	// style.css hides the <thead> under 900px and prints the label before each
	// cell's value instead.
	function td(label, content) {
		return E('td', { 'data-label': label }, content);
	}
	function val(text, cls) {
		var t = text || '-';
		return E('span', { 'class': 'sb-mon-val ' + (cls || ''), 'title': t }, t);
	}

	function renderRow(c) {
		var active = state.tab === 'active';
		var src = sourceOf(c);
		var closing = !!state.closing[c.id];
		var time = val(durationOf(c));
		// The duration is the one cell that changes without new data; the tick
		// updates these spans in place instead of rebuilding the tbody twice a
		// second (which would kill selection, hover and scroll position).
		state.timeCells.push({ c: c, el: time });
		return E('tr', { 'class': (active ? '' : 'closed') + (closing ? ' closing' : '') }, [
			td(_('Host'),  val(endpoint(c))),
			td(_('Type'),  val(networkOf(c), 'sb-mon-net')),
			td(_('Route'), val(routeOf(c), 'sb-mon-route')),
			td(_('Time'),  time),
			td(_('Downloaded'), val(fmtBytes(c.download))),
			td(_('Uploaded'),   val(fmtBytes(c.upload))),
			td(_('Source'), E('span', { 'class': 'sb-mon-val sb-mon-src',
				'title': src.name + ' ' + src.ip }, [
				E('span', { 'class': 'sb-mon-src-name' }, src.name || '-'),
				(src.ip && src.name !== src.ip)
					? E('span', { 'class': 'sb-mon-src-ip' }, src.ip) : ''
			])),
			// Closed connections are already terminated, so they get no Close
			// button — clicking it would DELETE a non-existent id (audit 9.1).
			td(_('Close'), (active && c.id) ? E('button', {
				'class': 'btn cbi-button sb-mon-row-close',
				'type': 'button',
				'data-action': 'close-row',
				'title': _('Close connection'),
				'aria-label': _('Close connection'),
				'disabled': closing ? '' : null,
				// c.id is captured BY VALUE, so a row rebuilt from later data
				// never acts on a stale connection (spec S2-6).
				'click': ui.createHandlerFn(this, (function (cid) {
					return function () { return closeConn(cid); };
				})(c.id))
			}, SbIcons.x()) : E('span', { 'class': 'sb-mon-val' }, '-'))
		]);
	}

	// A single full-width row carries every non-data state of the body:
	// loading / unreachable / nothing to show.
	function stateRow(text, cls) {
		return E('tr', { 'class': 'sb-mon-state-row' },
			E('td', { 'colspan': 8, 'class': 'sb-mon-state-cell' },
				E('div', { 'class': 'sb-mon-state ' + (cls || '') }, text)));
	}

	function tabButton(which) {
		return E('button', {
			'class': 'btn cbi-button sb-mon-tab',
			'type': 'button',
			'data-action': 'tab-' + which,
			'click': function () { state.tab = which; repaint(); }
		}, [
			E('span', { 'class': 'sb-mon-tab-label' },
				which === 'active' ? _('Active') : _('Closed')),
			E('span', { 'class': 'sb-mon-tab-badge' }, '0')
		]);
	}

	// Build the toolbar + table shell ONCE. The search <input>, device <select>,
	// tab buttons and tbody are stored on state.ui so subsequent repaints update
	// them in place — the <input> is never recreated, so focus and caret survive
	// the poll (spec S2-4).
	function mountChrome() {
		var tbody = E('tbody', {});
		var table = E('table', { 'class': 'table cbi-section-table sb-mon-table' }, [
			E('thead', {}, E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, _('Host')), E('th', {}, _('Type')), E('th', {}, _('Route')),
				E('th', {}, _('Time')), E('th', {}, '↓ ' + _('Downloaded')),
				E('th', {}, '↑ ' + _('Uploaded')), E('th', {}, _('Source')), E('th', {}, _('Close'))
			])),
			tbody
		]);
		var btnActive = tabButton('active');
		var btnClosed = tabButton('closed');
		var search = E('input', { 'type': 'search', 'placeholder': _('Search'),
			'class': 'cbi-input-text sb-mon-search-input', 'value': state.search,
			'autocomplete': 'off',
			'keyup': function (ev) {
				var v = ev.target.value;
				debouncedSearch(v, function (val_) { state.search = val_; repaint(); });
			} });
		var deviceSel = E('select', { 'class': 'cbi-input-select sb-mon-device',
			'change': function (ev) { state.filterDevice = ev.target.value; repaint(); } }, []);
		var btnCloseAll = E('button', {
			'class': 'btn cbi-button sb-mon-icon sb-mon-close-all',
			'type': 'button',
			'data-action': 'close-all',
			'title': _('Close all connections'), 'aria-label': _('Close all connections'),
			'click': ui.createHandlerFn(this, function () { return closeAll(); })
		}, SbIcons.x());
		var btnPause = E('button', { 'class': 'btn cbi-button sb-mon-icon sb-mon-pause',
			'type': 'button',
			'data-action': 'pause',
			'click': function () { setPaused(!state.paused); } }, SbIcons.pause());
		var controls = E('div', { 'class': 'sb-mon-controls' }, [
			E('div', { 'class': 'sb-mon-tabs' }, [ btnActive, btnClosed ]),
			E('div', { 'class': 'sb-mon-filters' }, [ deviceSel,
				E('label', { 'class': 'sb-mon-search' }, [
					E('span', { 'class': 'sb-mon-search-icon' }, SbIcons.search()),
					search
				]) ]),
			E('div', { 'class': 'sb-mon-actions' }, [ btnCloseAll, btnPause ])
		]);
		root.innerHTML = '';
		root.appendChild(controls);
		root.appendChild(E('div', { 'class': 'sb-mon-table-wrap' }, table));
		state.ui = { tbody: tbody, btnActive: btnActive, btnClosed: btnClosed,
		             deviceSel: deviceSel, search: search,
		             btnCloseAll: btnCloseAll, btnPause: btnPause };
	}

	function setPaused(on) {
		state.paused = !!on;
		state.pausedAt = state.paused ? Date.now() : 0;
		// Resuming replays whatever arrived while frozen, so nothing that opened
		// (or closed) during the pause is silently lost.
		if (!state.paused && state.pending) {
			var p = state.pending; state.pending = null;
			ingest(p);
		}
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
		sel.appendChild(E('option', { 'value': 'all' }, _('All')));
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

	// The Clash API being unreachable is the same thing as the service being
	// stopped from this view's point of view: there is nothing to show and
	// nothing to act on, so every control goes dead.
	function bodyState() {
		if (state.failed)  return { text: _('Connections are unavailable'), cls: 'sb-error' };
		if (state.loading) return { text: _('Loading connections'), cls: '' };
		return null;
	}

	function repaint() {
		if (!state.ui) mountChrome();
		if (hasSelectionInside()) return;
		var u = state.ui;
		var active = state.tab === 'active';
		var nActive = Object.keys(state.active).length;
		var nClosed = Object.keys(state.closed).length;
		var st = bodyState();

		rebuildDeviceOptions();
		u.tbody.innerHTML = '';
		state.timeCells = [];
		var rows = st ? [] : visibleConns();
		if (st)
			u.tbody.appendChild(stateRow(st.text, st.cls));
		else if (rows.length)
			rows.forEach(function (c) { u.tbody.appendChild(renderRow(c)); });
		else
			u.tbody.appendChild(stateRow(active
				? _('No active connections') : _('No closed connections')));

		u.btnActive.children[1].textContent = String(nActive);
		u.btnClosed.children[1].textContent = String(nClosed);
		// cbi-button-active is LuCI's themed selected-button class (audit 9.6);
		// sb-mon-tab-on is what the segmented control styles on.
		u.btnActive.className = 'btn cbi-button sb-mon-tab' +
			(active ? ' cbi-button-active sb-mon-tab-on' : '');
		u.btnClosed.className = 'btn cbi-button sb-mon-tab' +
			(active ? '' : ' cbi-button-active sb-mon-tab-on');
		u.btnActive.disabled = state.failed;
		u.btnClosed.disabled = state.failed;
		u.deviceSel.disabled = state.failed;
		u.search.disabled = state.failed;
		u.btnCloseAll.disabled = state.failed || nActive === 0;
		u.btnPause.disabled = state.failed;
		u.btnPause.innerHTML = '';
		u.btnPause.appendChild(state.paused ? SbIcons.play() : SbIcons.pause());
		u.btnPause.title = state.paused ? _('Resume updates') : _('Pause updates');
		u.btnPause.className = 'btn cbi-button sb-mon-icon sb-mon-pause' +
			(state.paused ? ' cbi-button-active' : '');
	}

	// The durations tick between polls; rebuilding the tbody for that would be
	// absurd, so only the Time spans are touched. Frozen while paused.
	function tickTimes() {
		if (state.paused) return;
		state.timeCells.forEach(function (o) {
			var t = durationOf(o.c);
			if (o.el.textContent !== t) { o.el.textContent = t; o.el.title = t; }
		});
	}

	function poll() {
		return callClashGet('/connections').then(function (res) {
			if (!res || res.status !== 'ok') throw new Error('clash api');
			var data;
			try { data = JSON.parse(res.body); } catch (e) { data = { connections: [] }; }
			applyPayload(data);
		// A rejected RPC (ubus/network down) fires every 1.5s from the poll
		// interval; without .catch each one is an uncaught rejection (spec
		// S2-1). Surface it in the node and stop the rejection propagating.
		}).catch(function () {
			state.loading = false;
			state.failed = true;
			repaint();
		});
	}

	// SPA navigation away from this view never calls stop() (main.js only
	// stops on sub-tab clicks within the view), so the interval would poll
	// forever (spec S2-2). The tick self-cancels once root leaves the DOM,
	// and a pagehide listener covers full-page teardown.
	function onPageHide() { stop(); }
	function start() {
		if (state.timer) return;
		repaint();   // loading state, before the first payload lands
		callDhcpLeases().then(function (r) {
			var arr = (r && (r.dhcp_leases || r.leases)) || [];
			(Array.isArray(arr) ? arr : []).forEach(function (l) {
				if (l.ipaddr) state.leases[l.ipaddr] = l.hostname || l.ipaddr;
			});
		}).catch(function () {});
		// tag -> { name }: turns a subscription node's content-hash tag into the
		// human name in the Route column. Absent on an older backend — the raw
		// tag is then shown, which is what routeName() falls back to anyway.
		callOutboundMeta().then(function (res) {
			state.names = (res && res.meta) || {};
		}).catch(function () {});
		poll();
		state.timer = setInterval(function () {
			if (root.isConnected === false) { stop(); return; }
			if (document.visibilityState !== 'visible') return;
			tickTimes();
			if (++state.tick % POLL_EVERY_TICKS === 0) poll();
		}, TICK_MS);
		if (typeof window !== 'undefined' && window.addEventListener)
			window.addEventListener('pagehide', onPageHide);
	}
	function stop() {
		if (state.timer) { clearInterval(state.timer); state.timer = null; }
		if (state.searchTimer) { clearTimeout(state.searchTimer); state.searchTimer = null; }
		if (typeof window !== 'undefined' && window.removeEventListener)
			window.removeEventListener('pagehide', onPageHide);
	}

	// `poll`/`debouncedSearch`/`_searchHay`/`setPaused`/`_tickTimes` are exported
	// for the regression harness (tests/ui/test_monitoring_js.test.ts);
	// production callers use start()/stop().
	return { node: root, start: start, stop: stop, poll: poll,
	         setPaused: setPaused, _tickTimes: tickTimes,
	         debouncedSearch: debouncedSearch, _searchHay: searchHay };
}

return L.Class.extend({ buildMonitoring: buildMonitoring });
