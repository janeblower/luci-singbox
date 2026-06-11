'use strict';
'require view';
'require form';
'require rpc';
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
'require view.singbox-ui.widgets.action-bar as SbActionBar';
'require view.singbox-ui.widgets.status-panel as SbStatusPanel';
'require view.singbox-ui.widgets.bbolt-panel as SbBboltPanel';
'require view.singbox-ui.lib.subscription_view as SbSubView';
'require view.singbox-ui.lib.view_state as SbViewState';

return view.extend({
	load: function () {
		var callProtocolSchema = rpc.declare({
			object: 'singbox-ui',
			method: 'protocol_schema',
		});
		return Promise.all([
			uci.load('singbox-ui'),
			L.resolveDefault(callProtocolSchema(), null).then(function (r) {
				if (r && r.status === 'ok') {
					SbViewState.setSchema(r.schema);
				} else {
					L.ui.addNotification(null,
						E('p', _('Failed to load protocol schema. Some forms may be incomplete; restart rpcd or reinstall package.')),
						'warning');
				}
			}),
			SbSubView.loadAllExpansions().then(function (cache) { SbViewState.setSubExpand(cache); }),
		]);
	},

	render: function () {
		var self = this;
		var mInbounds     = SbTabInbounds.buildInboundsMap();
		var mOutbounds    = SbTabOutbounds.buildOutboundsMap();
		var mRulesets     = SbTabRulesets.buildRulesetsMap();
		var mRouteRules   = SbTabRouting.buildRouteRulesMap();
		var mRouteDefault = SbTabRouting.buildRouteDefaultMap();
		var mDns          = SbTabDns.buildDnsMap();
		var mGeneral      = SbTabGeneral.buildGeneralMap();
		var mon           = SbTabMon.buildMonitoring();

		self._maps = [ mInbounds, mOutbounds, mRulesets, mRouteRules, mRouteDefault, mDns, mGeneral ];

		return Promise.all(self._maps.map(function (m) { return m.render(); }))
		.then(function (nodes) {
			var inboundsNode   = nodes[0];
			var outboundsNode  = nodes[1];
			var rulesetsNode   = nodes[2];
			// bbolt-client helper panel at the top of the Rule-Sets tab (toggles
			// with the tab since it lives inside rulesetsNode).
			var bboltHolder = E('div', { 'class': 'sb-bbolt' });
			rulesetsNode.insertBefore(bboltHolder, rulesetsNode.firstChild);
			var routerulesNode = nodes[3];
			var routedefNode   = nodes[4];
			var dnsNode        = nodes[5];
			var generalNode    = nodes[6];

			var statusHolder = E('div', { 'class': 'sb-status' });
			var actionBar    = SbActionBar.renderActionBar(statusHolder);

			// Inject the shared CSS once per page render. L.resource() resolves
			// to /luci-static/resources/view/singbox-ui/style.css — same pattern
			// as luci-app-nlbwmon / luci-app-mwan3 (C2.2.9).
			var cssLink = E('link', {
				'rel':  'stylesheet',
				'type': 'text/css',
				'href': L.resource('view/singbox-ui/style.css')
			});

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
				cssLink,
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

			// Defer tab wiring until after the DOM is attached. A microtask
			// (Promise.resolve().then) runs before the next macrotask without
			// the 0-delay flicker setTimeout introduced (spec C2.2.10).
			Promise.resolve().then(function () {
				SbCommon.wireTabs(root, '.sb-subtab-header', {
					outbounds:  outboundsNode,
					rulesets:   rulesetsNode,
					routerules: routerulesNode,
					routedef:   routedefNode
				}, 'outbounds');
				SbCommon.wireTabs(root, '.sb-tab-header', {
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
				SbStatusPanel.renderStatusPanel(statusHolder);
				SbBboltPanel.renderBboltPanel(bboltHolder);
				SbSubView.injectChildRows(outboundsNode, SbViewState.getSubExpand());
			});

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
