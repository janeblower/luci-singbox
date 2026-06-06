'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

var callClash      = SbRpc.callClash;
var callDhcpLeases = SbRpc.callDhcpLeases;

function buildMonitoring() {
	var state = {
		timer: null, prevConns: {}, closed: [], leases: {},
		filterDevice: 'all', search: '', tab: 'active',
		lastDown: null, lastUp: null
	};
	var root = E('div', { 'class': 'sb-monitoring' });

	function fmtBytes(n) {
		n = n || 0; var u = ['B','KB','MB','GB','TB']; var i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return n.toFixed(i ? 1 : 0) + u[i];
	}
	function nameFor(ip) { return state.leases[ip] || ip; }

	function closeConn(id) {
		return callClash('DELETE', '/connections/' + id, '').then(poll);
	}
	function closeAll() {
		return callClash('DELETE', '/connections', '').then(poll);
	}

	function renderTable(conns) {
		var rows = conns.filter(function (c) {
			var src = (c.metadata && c.metadata.sourceIP) || '';
			if (state.filterDevice !== 'all' && src !== state.filterDevice) return false;
			if (state.search) {
				var hay = JSON.stringify(c).toLowerCase();
				if (hay.indexOf(state.search.toLowerCase()) < 0) return false;
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
					'click': ui.createHandlerFn(this, function () { return closeConn(c.id); })
				}, _('Close')) : '')
			]);
		});
		return E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, _('Host')), E('th', {}, _('Device')), E('th', {}, _('Chain')),
				E('th', {}, _('Down')), E('th', {}, _('Up')), E('th', {}, '')
			])
		].concat(rows.length ? rows : [ E('tr', {}, E('td', { 'colspan': 6 }, E('em', {}, _('No connections')))) ]));
	}

	function repaint(data) {
		var conns = (data && data.connections) || [];
		var nowIds = {}; conns.forEach(function (c) { if (c.id) nowIds[c.id] = c; });
		Object.keys(state.prevConns).forEach(function (id) {
			if (!nowIds[id]) state.closed.unshift(state.prevConns[id]);
		});
		if (state.closed.length > 100) state.closed.length = 100;
		state.prevConns = nowIds;

		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		var dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		var uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;

		var devices = {};
		conns.forEach(function (c) { var s = c.metadata && c.metadata.sourceIP; if (s) devices[s] = true; });

		root.innerHTML = '';
		root.appendChild(E('div', { 'style': 'display:flex;gap:1em;flex-wrap:wrap;align-items:center;margin:.5em 0' }, [
			E('button', { 'class': 'btn cbi-button' + (state.tab === 'active' ? ' cbi-button-action' : ''),
				'click': function () { state.tab = 'active'; repaint(data); } }, _('Active') + ' ' + conns.length),
			E('button', { 'class': 'btn cbi-button' + (state.tab === 'closed' ? ' cbi-button-action' : ''),
				'click': function () { state.tab = 'closed'; repaint(data); } }, _('Closed') + ' ' + state.closed.length),
			E('input', { 'type': 'search', 'placeholder': _('Search'), 'value': state.search,
				'keyup': function (ev) { state.search = ev.target.value; repaint(data); } }),
			(function () {
				var opts = [ E('option', { 'value': 'all' }, _('All devices')) ];
				Object.keys(devices).forEach(function (ip) {
					var attr = { 'value': ip };
					if (state.filterDevice === ip) attr.selected = '';
					opts.push(E('option', attr, nameFor(ip)));
				});
				return E('select', {
					'change': function (ev) { state.filterDevice = ev.target.value; repaint(data); }
				}, opts);
			})(),
			E('button', { 'class': 'btn cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(this, function () { return closeAll(); }) }, _('Close all')),
			E('span', {}, _('↓') + ' ' + fmtBytes(dRate) + '/s  ' + _('↑') + ' ' + fmtBytes(uRate) + '/s' +
				'  (' + _('total') + ' ↓' + fmtBytes(down) + ' ↑' + fmtBytes(up) + ')')
		]));
		root.appendChild(renderTable(state.tab === 'active' ? conns : state.closed));
	}

	function poll() {
		return callClash('GET', '/connections', '').then(function (res) {
			if (!res || res.status !== 'ok') {
				root.innerHTML = '';
				root.appendChild(E('em', {}, _('Clash API unreachable — enable it in settings and restart.')));
				return;
			}
			var data;
			try { data = JSON.parse(res.body); } catch (e) { data = { connections: [] }; }
			repaint(data);
		});
	}

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
			if (document.visibilityState === 'visible') poll();
		}, 1500);
	}
	function stop() { if (state.timer) { clearInterval(state.timer); state.timer = null; } }

	return { node: root, start: start, stop: stop };
}

return L.Class.extend({ buildMonitoring: buildMonitoring });
