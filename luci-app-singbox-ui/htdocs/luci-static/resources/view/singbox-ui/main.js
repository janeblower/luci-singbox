'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.importers.inbound as SbImpInbound';
'require view.singbox-ui.importers.outbound as SbImpOutbound';
'require tools.widgets as widgets';
'require view.singbox-ui.tabs.inbounds as SbTabInbounds';
'require view.singbox-ui.tabs.outbounds as SbTabOutbounds';
'require view.singbox-ui.tabs.rulesets as SbTabRulesets';
'require view.singbox-ui.tabs.routing as SbTabRouting';
'require view.singbox-ui.tabs.dns as SbTabDns';

var callRefresh    = SbRpc.callRefresh;
var callRestart    = SbRpc.callRestart;
var callStatus     = SbRpc.callStatus;
var callReadConfig = SbRpc.callReadConfig;
var callClash      = SbRpc.callClash;
var callDhcpLeases = SbRpc.callDhcpLeases;

var loadOutboundList = SbCommon.loadOutboundList;
var addRenameField   = SbCommon.addRenameField;
var wireTabs         = SbCommon.wireTabs;
var notify           = SbCommon.notify;

var SB_INBOUND_KNOWN       = SbImpInbound.SB_INBOUND_KNOWN;
var __sb_jsonImportInbound = SbImpInbound.jsonImportInbound;

var SB_OUTBOUND_KNOWN       = SbImpOutbound.SB_OUTBOUND_KNOWN;
var __sb_jsonImportOutbound = SbImpOutbound.jsonImportOutbound;

var SB_INBOUND_PROTOCOLS = SbTabInbounds.SB_INBOUND_PROTOCOLS;
var openJsonImportModal  = SbTabInbounds.openJsonImportModal;
var buildInboundsMap     = SbTabInbounds.buildInboundsMap;

var buildOutboundsMap = SbTabOutbounds.buildOutboundsMap;

var buildRulesetsMap = SbTabRulesets.buildRulesetsMap;

var buildRouteRulesMap   = SbTabRouting.buildRouteRulesMap;
var buildRouteDefaultMap = SbTabRouting.buildRouteDefaultMap;

var loadDnsServerList = SbTabDns.loadDnsServerList;
var buildDnsMap       = SbTabDns.buildDnsMap;

function buildGeneralMap() {
	var m = new form.Map('singbox-ui', _('General'),
		_('Global sing-box settings: cache file, log.'));

	var s, o;

	// --- Cache file ---
	s = m.section(form.NamedSection, 'cache', 'cache', _('Cache file'),
		_('Persistent cache for proxies, DNS responses, and fakeip mappings.'));

	o = s.option(form.Flag, 'enabled', _('Enable cache file'));
	o.default = '1';

	o = s.option(form.ListValue, 'storage', _('Storage'));
	o.value('ram',    _('RAM (/tmp/, lost on reboot)'));
	o.value('flash',  _('Flash (/etc/sing-box/, persistent)'));
	o.value('custom', _('Custom path'));
	o.default = 'ram';
	o.depends('enabled', '1');

	o = s.option(form.Value, 'path', _('Custom path'));
	o.placeholder = '/srv/singbox-cache.db';
	o.depends({ enabled: '1', storage: 'custom' });
	o.validate = function (section_id, value) {
		if (value == null || value === '') return _('Path is required when storage = Custom');
		if (value.charAt(0) !== '/') return _('Path must be absolute');
		return true;
	};

	o = s.option(form.Flag, 'store_fakeip', _('Persist fakeip mappings'));
	o.default = '1';
	o.depends('enabled', '1');
	o.description = _('Effective only when a DNS server of type fakeip is enabled.');

	// -- Log --
	s = m.section(form.NamedSection, 'log', 'log', _('Log'));
	s.anonymous = true;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default = '1';
	o.rmempty = false;
	o = s.option(form.ListValue, 'level', _('Level'));
	['trace','debug','info','warn','error','fatal','panic'].forEach(function (lv) {
		o.value(lv, lv);
	});
	o.default = 'info';
	o.depends('enabled', '1');
	o = s.option(form.Value, 'output', _('Output file (empty = procd stdout)'));
	o.depends('enabled', '1');

	return m;
}

function renderActionBar(statusHolder) {
	function refreshStatus() { renderStatusPanel(statusHolder); }
	function btn(label, handler) {
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				return Promise.resolve(handler.call(this)).then(refreshStatus);
			})
		}, _(label));
	}
	return E('div', { 'class': 'sb-actionbar', 'style': 'display:flex;gap:.5em;margin:.5em 0' }, [
		btn(_('Refresh subscriptions'), function () {
			return notify(callRefresh('subscriptions'), 'Done', _('Refresh subscriptions failed'));
		}),
		btn(_('Refresh rule-sets'), function () {
			return notify(callRefresh('rulesets'),      'Done', _('Refresh rule-sets failed'));
		}),
		btn(_('Restart service'), function () {
			return notify(callRestart(),                'Done', _('Restart failed'));
		}),
		btn(_('Preview generated config'), function () {
			return callReadConfig().then(function (res) {
				if (!res || res.status !== 'ok') {
					ui.addNotification(null, E('p', (res && res.message) || _('not generated')), 'danger');
					return;
				}
				ui.showModal(_('Preview generated config'), [
					E('pre', { 'style': 'max-height:60vh;overflow:auto;font-family:monospace' }, res.content),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
					])
				]);
			});
		})
	]);
}

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

function renderStatusPanel(holder) {
	// Use the server-supplied `now` so 'X ago' stays accurate even when the
	// browser clock has drifted from the router (common on routers without NTP).
	function fmtAgo(now, mt) {
		if (!mt) return _('never');
		var ago = Math.max(0, now - mt);
		if (ago < 60)    return ago + 's';
		if (ago < 3600)  return Math.floor(ago / 60)   + 'm';
		if (ago < 86400) return Math.floor(ago / 3600) + 'h';
		return Math.floor(ago / 86400) + 'd';
	}

	return callStatus().then(function (res) {
		holder.innerHTML = '';
		if (!res || res.status !== 'ok') {
			holder.appendChild(E('em', _('Status unavailable')));
			return;
		}
		var rows = [];
		rows.push(E('div', {}, [
			E('strong', _('Status') + ': '),
			E('span', { 'style': 'color:' + (res.running ? '#2e7d32' : '#c62828') },
			  res.running ? _('Service running') : _('Service stopped'))
		]));
		function entryList(label, items) {
			if (!items || !items.length) return null;
			return E('div', {}, [
				E('strong', label + ': '),
				items.map(function (it) {
					return it.name + ' (' + fmtAgo(res.now, it.mtime) + ')';
				}).join(', ')
			]);
		}
		var sub = entryList(_('Subscriptions'), res.subscriptions);
		if (sub) rows.push(sub);
		var rs = entryList(_('Rule-Sets'), res.rulesets);
		if (rs) rows.push(rs);

		rows.forEach(function (r) { holder.appendChild(r); });
	});
}

return view.extend({
	load: function () { return uci.load('singbox-ui'); },

	render: function () {
		var self = this;
		var mInbounds     = buildInboundsMap();
		var mOutbounds    = buildOutboundsMap();
		var mRulesets     = buildRulesetsMap();
		var mRouteRules   = buildRouteRulesMap();
		var mRouteDefault = buildRouteDefaultMap();
		var mDns          = buildDnsMap();
		var mGeneral      = buildGeneralMap();
		var mon           = buildMonitoring();

		self._maps = [ mInbounds, mOutbounds, mRulesets, mRouteRules, mRouteDefault, mDns, mGeneral ];

		return Promise.all(self._maps.map(function (m) { return m.render(); }))
		.then(function (nodes) {
			var inboundsNode   = nodes[0];
			var outboundsNode  = nodes[1];
			var rulesetsNode   = nodes[2];
			var routerulesNode = nodes[3];
			var routedefNode   = nodes[4];
			var dnsNode        = nodes[5];
			var generalNode    = nodes[6];

			var statusHolder = E('div', { 'class': 'sb-status', 'style': 'margin:.5em 0;padding:.5em;border:1px solid #ddd;border-radius:4px' });
			var actionBar    = renderActionBar(statusHolder);

			var outputWrap = E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-subtab-header' }, [
					E('li', { 'data-tab': 'outbounds'  }, _('Outbounds')),
					E('li', { 'data-tab': 'rulesets'   }, _('Rule-Sets')),
					E('li', { 'data-tab': 'routerules' }, _('Route Rules')),
					E('li', { 'data-tab': 'routedef'   }, _('Default'))
				]),
				outboundsNode,
				rulesetsNode,
				routerulesNode,
				routedefNode
			]);

			var root = E('div', {}, [
				actionBar,
				statusHolder,
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', { 'data-tab': 'inbounds'   }, _('Inbounds')),
					E('li', { 'data-tab': 'output'     }, _('Output')),
					E('li', { 'data-tab': 'dns'        }, _('DNS')),
					E('li', { 'data-tab': 'monitoring' }, _('Monitoring')),
					E('li', { 'data-tab': 'general'    }, _('General'))
				]),
				inboundsNode,
				outputWrap,
				dnsNode,
				mon.node,
				generalNode
			]);

			setTimeout(function () {
				wireTabs(root, '.sb-subtab-header', {
					outbounds:  outboundsNode,
					rulesets:   rulesetsNode,
					routerules: routerulesNode,
					routedef:   routedefNode
				}, 'outbounds');
				wireTabs(root, '.sb-tab-header', {
					inbounds:   inboundsNode,
					output:     outputWrap,
					dns:        dnsNode,
					monitoring: mon.node,
					general:    generalNode
				}, 'inbounds');
				root.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.addEventListener('click', function () {
						if (el.getAttribute('data-tab') === 'monitoring') mon.start();
						else mon.stop();
					});
				});
				renderStatusPanel(statusHolder);
			}, 0);

			return root;
		});
	},

	handleSave: function (ev) {
		// All maps share one uci.state, so calling m.save() on each in parallel
		// fires duplicate RPC delete/set/add calls — the second copy of any
		// delete fails with "ubus code 4: Resource not found" because the
		// first copy already removed the target. Parse all maps to stage
		// changes locally, then flush once via uci.save().
		return Promise.all(this._maps.map(function (m) {
			return m.parse();
		})).then(function () { return uci.save(); });
	},

	handleSaveApply: function (ev, mode) {
		return this.handleSave(ev, true).then(function () {
			return ui.changes.apply(mode === 'force-apply');
		});
	},

	handleReset: null
});
