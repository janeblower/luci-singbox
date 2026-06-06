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
'require view.singbox-ui.tabs.general as SbTabGeneral';
'require view.singbox-ui.tabs.monitoring as SbTabMon';

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

var buildGeneralMap = SbTabGeneral.buildGeneralMap;

var buildMonitoring = SbTabMon.buildMonitoring;

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
