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
'require view.singbox-ui.tabs.route as SbTabRoute';
'require view.singbox-ui.tabs.dns as SbTabDns';
'require view.singbox-ui.tabs.general as SbTabGeneral';
'require view.singbox-ui.tabs.monitoring as SbTabMon';
'require view.singbox-ui.tabs.dashboard as SbTabDash';
'require view.singbox-ui.widgets.action-bar as SbActionBar';
'require view.singbox-ui.widgets.status-panel as SbStatusPanel';
'require view.singbox-ui.lib.view_state as SbViewState';
'require view.singbox-ui.lib.plugins as SbPlugins';

return view.extend({
	load: function () {
		var self = this;
		var callProtocolSchema = rpc.declare({
			object: 'singbox-ui',
			method: 'protocol_schema',
		});
		var callStatusDetail = rpc.declare({ object: 'singbox-ui', method: 'status_detail' });
		return Promise.all([
			uci.load('singbox-ui'),
			L.resolveDefault(uci.load('network'), null),  // bind_interface dropdown source
			L.resolveDefault(callProtocolSchema(), null).then(function (r) {
				if (r && r.status === 'ok') {
					SbViewState.setSchema(r.schema);
				} else {
					ui.addNotification(null,
						E('p', _('Failed to load protocol schema. Some forms may be incomplete; restart rpcd or reinstall package.')),
						'warning');
				}
			}),
			L.resolveDefault(callStatusDetail(), null).then(function (r) {
				if (r && r.core_version != null) SbViewState.setCoreVersion(r.core_version);
			}),
			SbPlugins.loadEnabled().then(function (plugins) { self._plugins = plugins; }),
		]).then(function () {
			// ui_compat_only is a UI-only flag on the main/global settings
			// section, read once per page load. When set, version-incompatible
			// fields are hidden instead of shown disabled (see descriptor_form /
			// common.js version gates). Absent section/option → default false.
			var v = uci.get('singbox-ui', 'main', 'ui_compat_only');
			SbViewState.setCompatOnly(v === '1');
		});
	},

	render: function () {
		var self = this;
		var plugins = self._plugins || [];
		SbTabOutbounds.setPluginOutboundTypes(SbPlugins.collectOutboundTypes(plugins));
		var mInbounds     = SbTabInbounds.buildInboundsMap();
		var mOutbounds    = SbTabOutbounds.buildOutboundsMap();
		var mRouteRules   = SbTabRoute.buildRouteRulesMap();
		var mRulesets     = SbTabRoute.buildRuleSetsMap();
		var mRouteDefault = SbTabRoute.buildRouteDefaultMap();
		var mDns          = SbTabDns.buildDnsMap();
		var mGeneral      = SbTabGeneral.buildGeneralMap();
		var mon           = SbTabMon.buildMonitoring();
		var dash          = SbTabDash.buildDashboard();

		var pluginTabs = SbPlugins.collectTabs(plugins);
		SbPlugins.applySettingsSections(plugins, mGeneral);
		self._maps = [ mInbounds, mOutbounds, mRouteRules, mRulesets, mRouteDefault, mDns, mGeneral ];
		pluginTabs.forEach(function (t) { self._maps.push(t.build()); });

		return Promise.all(self._maps.map(function (m) { return m.render(); }))
		.then(function (nodes) {
			var inboundsNode   = nodes[0];
			var outboundsNode  = nodes[1];
			var routerulesNode = nodes[2];
			var rulesetsNode   = nodes[3];
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

			var routeWrap = E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-subtab-header' }, [
					E('li', { 'data-tab': 'routerules' }, _('Route Rules')),
					E('li', { 'data-tab': 'rulesets'   }, _('Rule-Sets')),
					E('li', { 'data-tab': 'routedef'   }, _('Default'))
				]),
				routerulesNode,
				rulesetsNode,
				routedefNode
			]);

			var tabHeader = E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
				E('li', { 'data-tab': 'inbounds'   }, _('Inbounds')),
				E('li', { 'data-tab': 'outbounds'  }, _('Outbounds')),
				E('li', { 'data-tab': 'route'      }, _('Route')),
				E('li', { 'data-tab': 'dns'        }, _('DNS')),
				E('li', { 'data-tab': 'dashboard'  }, _('Dashboard')),
				E('li', { 'data-tab': 'monitoring' }, _('Monitoring')),
				E('li', { 'data-tab': 'general'    }, _('General'))
			]);
			var pluginTabMap = {};
			pluginTabs.forEach(function (t, i) {
				var node = nodes[7 + i];
				tabHeader.appendChild(E('li', { 'data-tab': t.id }, _(t.label)));
				pluginTabMap[t.id] = node;
			});

			var rootChildren = [cssLink, actionBar, statusHolder, tabHeader,
				inboundsNode, outboundsNode, routeWrap, dnsNode, dash.node, mon.node, generalNode];
			pluginTabs.forEach(function (t, i) { rootChildren.push(nodes[7 + i]); });
			var root = E('div', {}, rootChildren);

			// Defer tab wiring until after the DOM is attached. A microtask
			// (Promise.resolve().then) runs before the next macrotask without
			// the 0-delay flicker setTimeout introduced (spec C2.2.10).
			Promise.resolve().then(function () {
				SbCommon.wireTabs(root, '.sb-subtab-header', {
					routerules: routerulesNode,
					rulesets:   rulesetsNode,
					routedef:   routedefNode
				}, 'routerules');
				var tabMap = {
					inbounds:   inboundsNode,
					outbounds:  outboundsNode,
					route:      routeWrap,
					dns:        dnsNode,
					dashboard:  dash.node,
					monitoring: mon.node,
					general:    generalNode
				};
				Object.keys(pluginTabMap).forEach(function (k) { tabMap[k] = pluginTabMap[k]; });
				SbCommon.wireTabs(root, '.sb-tab-header', tabMap, 'inbounds');
				root.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.addEventListener('click', function () {
						var tab = el.getAttribute('data-tab');
						if (tab === 'monitoring') { mon.start(); dash.stop(); }
						else if (tab === 'dashboard') { dash.start(); mon.stop(); }
						else { mon.stop(); dash.stop(); }
					});
				});
				SbStatusPanel.renderStatusPanel(statusHolder);
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
		return this.handleSave(ev).then(function () {
			return ui.changes.apply(mode === 'force-apply');
		});
	},

	handleReset: null
});
