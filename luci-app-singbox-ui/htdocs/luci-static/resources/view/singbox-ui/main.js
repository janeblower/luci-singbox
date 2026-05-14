'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require tools.widgets as widgets';

// rpcd binding: singbox-ui restart
var callRestart = rpc.declare({
	object: 'singbox-ui',
	method: 'restart'
});

// Custom widget: a <textarea> for editing raw JSON in the outbound modal.
var TextareaValue = form.Value.extend({
	renderWidget: function (section_id, option_index, cfgvalue) {
		return E('textarea', {
			'name':  this.cbid(section_id),
			'class': 'cbi-input-textarea',
			'rows':  5,
			'style': 'width:100%;font-family:monospace'
		}, [ cfgvalue != null ? cfgvalue : '' ]);
	},
	formvalue: function (section_id) {
		var node = this.map.findElement('name', this.cbid(section_id));
		return node ? node.value : null;
	}
});

return view.extend({
	load: function () {
		return uci.load('singbox-ui');
	},

	render: function () {
		var self = this;
		var s, o;

		// =================================================================
		// Input map — unchanged from Phase 2
		// =================================================================
		var mInput = new form.Map('singbox-ui', _('Input'),
			_('Configure FakeIP and TProxy inbound. ' +
			  'nftables redirect rules are applied automatically ' +
			  'when TProxy is enabled and the service starts.'));

		s = mInput.section(form.NamedSection, 'fakeip', 'fakeip', _('FakeIP'));
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o = s.option(form.DynamicList, 'inet4_range', _('IPv4 ranges'));
		o.datatype = 'cidr4';
		o.placeholder = '198.18.0.0/15';
		o = s.option(form.DynamicList, 'inet6_range', _('IPv6 ranges'));
		o.datatype = 'cidr6';
		o.placeholder = 'fc00::/18';

		s = mInput.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
		s.anonymous = true;
		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;
		o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
		o.noaliases = true;
		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '7893';

		// =================================================================
		// Output: Outbounds sub-tab
		// =================================================================
		var mOutbounds = new form.Map('singbox-ui', _('Outbounds'),
			_('Define outbounds: direct, block, or proxy via interface / URL / raw JSON / subscription.'));

		s = mOutbounds.section(form.GridSection, 'outbound', null);
		s.anonymous  = false;
		s.addremove  = true;
		s.sortable   = true;
		s.modaltitle = function (section_id) {
			var action = uci.get('singbox-ui', section_id, 'action') || '';
			return _('Outbound') + ': ' + section_id +
			       (action ? ' (' + _(action) + ')' : '');
		};

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default  = '1';
		o.editable = true;

		o = s.option(form.ListValue, 'action', _('Action'));
		o.value('direct', _('Direct'));
		o.value('block',  _('Block'));
		o.value('proxy',  _('Proxy'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'proxy_type', _('Type'));
		o.modalonly = true;
		o.value('interface',    _('Interface'));
		o.value('url',          _('URL (share link)'));
		o.value('json',         _('Raw JSON'));
		o.value('subscription', _('Subscription URL'));
		o.depends('action', 'proxy');

		o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
		o.modalonly = true;
		o.noaliases = true;
		o.depends({ action: 'proxy', proxy_type: 'interface' });

		o = s.option(form.Value, 'proxy_url', _('URL'));
		o.modalonly   = true;
		o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
		o.depends({ action: 'proxy', proxy_type: 'url' });

		o = s.option(TextareaValue, 'proxy_json', _('JSON outbound'));
		o.modalonly   = true;
		o.placeholder = '{"type":"vless","server":"host","server_port":443,"uuid":"..."}';
		o.depends({ action: 'proxy', proxy_type: 'json' });

		o = s.option(form.Value, 'sub_url', _('Subscription URL'));
		o.modalonly   = true;
		o.placeholder = 'https://sub.example.com/config';
		o.depends({ action: 'proxy', proxy_type: 'subscription' });

		o = s.option(form.ListValue, 'sub_update_via', _('Update via'));
		o.modalonly = true;
		o.depends({ action: 'proxy', proxy_type: 'subscription' });
		o.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec.proxy_type === 'interface')
				o.value(sec['.name'], sec['.name'] + ' (' + (sec.interface || '?') + ')');
		});

		o = s.option(form.Value, 'sub_interval', _('Update interval (s)'));
		o.modalonly   = true;
		o.datatype    = 'uinteger';
		o.placeholder = '3600';
		o.depends({ action: 'proxy', proxy_type: 'subscription' });

		// =================================================================
		// Output: Rule-Sets sub-tab
		// =================================================================
		var mRulesets = new form.Map('singbox-ui', _('Rule-Sets'),
			_('Remote (.srs/.json) or local rule-sets, referenced by route rules.'));

		s = mRulesets.section(form.GridSection, 'ruleset', null);
		s.anonymous  = false;
		s.addremove  = true;
		s.sortable   = true;
		s.modaltitle = function (section_id) { return _('Rule-Set') + ': ' + section_id; };

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default  = '1';
		o.editable = true;

		o = s.option(form.ListValue, 'type', _('Type'));
		o.value('remote', _('Remote'));
		o.value('local',  _('Local'));
		o.default = 'remote';
		o.rmempty = false;

		o = s.option(form.Value, 'url', _('URL'));
		o.placeholder = 'https://example.com/geosite.srs';
		o.depends('type', 'remote');

		o = s.option(form.Value, 'path', _('Path'));
		o.modalonly   = true;
		o.placeholder = '/etc/singbox-ui/rules/cn.json';
		o.depends('type', 'local');

		o = s.option(form.ListValue, 'format', _('Format'));
		o.modalonly = true;
		o.value('binary', _('Binary (.srs)'));
		o.value('source', _('Source (.json)'));
		o.default = 'binary';

		o = s.option(form.Flag, 'dns_fakeip', _('Route DNS to FakeIP'));
		o.modalonly = true;
		o.default   = '0';

		o = s.option(form.Value, 'dns_fakeip_tag', _('FakeIP DNS tag'));
		o.modalonly   = true;
		o.placeholder = 'fakeip';
		o.depends('dns_fakeip', '1');

		o = s.option(form.Flag, 'nft_rules', _('Create nftables rules'));
		o.modalonly = true;
		o.default   = '0';

		o = s.option(form.Value, 'update_interval', _('Update interval (s)'));
		o.modalonly   = true;
		o.datatype    = 'uinteger';
		o.placeholder = '86400';
		o.depends('type', 'remote');

		// =================================================================
		// Output: Route Rules sub-tab
		// =================================================================
		var mRouteRules = new form.Map('singbox-ui', _('Route Rules'),
			_('Match traffic against one or more rule-sets and send it to an outbound, direct, or block.'));

		s = mRouteRules.section(form.GridSection, 'route_rule', null);
		s.anonymous  = false;
		s.addremove  = true;
		s.sortable   = true;
		s.modaltitle = function (section_id) { return _('Route Rule') + ': ' + section_id; };

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.default  = '1';
		o.editable = true;

		var rulesetNames = uci.sections('singbox-ui', 'ruleset').map(function (sec) {
			return sec['.name'];
		});

		o = s.option(form.DynamicList, 'ruleset', _('Rule-Sets'));
		o.placeholder = rulesetNames.join(', ');

		o = s.option(form.ListValue, 'action', _('Action'));
		o.value('direct',   _('Direct'));
		o.value('block',    _('Block'));
		o.value('outbound', _('Outbound'));
		o.default = 'direct';
		o.rmempty = false;

		o = s.option(form.ListValue, 'outbound', _('Outbound'));
		o.depends('action', 'outbound');
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			o.value(sec['.name'], sec['.name']);
		});

		self._mInput      = mInput;
		self._mOutbounds  = mOutbounds;
		self._mRulesets   = mRulesets;
		self._mRouteRules = mRouteRules;

		// =================================================================
		// Render with top-level (Input/Output) and Output sub-tabs
		// =================================================================
		return Promise.all([
			mInput.render(),
			mOutbounds.render(),
			mRulesets.render(),
			mRouteRules.render()
		]).then(function (nodes) {
			var inputNode      = nodes[0];
			var outboundsNode  = nodes[1];
			var rulesetsNode   = nodes[2];
			var routerulesNode = nodes[3];

			function switchSubTab(ev) {
				var tab = ev.currentTarget.getAttribute('data-tab');
				document.querySelectorAll('.sb-subtab-header > li').forEach(function (el) {
					el.classList.remove('cbi-tab', 'cbi-tab-disabled');
					el.classList.add(
						el.getAttribute('data-tab') === tab ? 'cbi-tab' : 'cbi-tab-disabled'
					);
				});
				outboundsNode.style.display  = (tab === 'outbounds')  ? '' : 'none';
				rulesetsNode.style.display   = (tab === 'rulesets')   ? '' : 'none';
				routerulesNode.style.display = (tab === 'routerules') ? '' : 'none';
			}

			var outputWrap = E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-subtab-header' }, [
					E('li', {
						'class':    'cbi-tab',
						'data-tab': 'outbounds',
						'click':    switchSubTab
					}, _('Outbounds')),
					E('li', {
						'class':    'cbi-tab-disabled',
						'data-tab': 'rulesets',
						'click':    switchSubTab
					}, _('Rule-Sets')),
					E('li', {
						'class':    'cbi-tab-disabled',
						'data-tab': 'routerules',
						'click':    switchSubTab
					}, _('Route Rules'))
				]),
				outboundsNode,
				rulesetsNode,
				routerulesNode
			]);

			rulesetsNode.style.display   = 'none';
			routerulesNode.style.display = 'none';
			outputWrap.style.display     = 'none';

			function switchTopTab(ev) {
				var tab = ev.currentTarget.getAttribute('data-tab');
				document.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.classList.remove('cbi-tab', 'cbi-tab-disabled');
					el.classList.add(
						el.getAttribute('data-tab') === tab ? 'cbi-tab' : 'cbi-tab-disabled'
					);
				});
				inputNode.style.display  = (tab === 'input')  ? '' : 'none';
				outputWrap.style.display = (tab === 'output') ? '' : 'none';
			}

			return E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', {
						'class':    'cbi-tab',
						'data-tab': 'input',
						'click':    switchTopTab
					}, _('Input')),
					E('li', {
						'class':    'cbi-tab-disabled',
						'data-tab': 'output',
						'click':    switchTopTab
					}, _('Output'))
				]),
				inputNode,
				outputWrap
			]);
		});
	},

	handleSave: function (ev) {
		return Promise.all([
			this._mInput.save(),
			this._mOutbounds.save(),
			this._mRulesets.save(),
			this._mRouteRules.save()
		]);
	},

	handleSaveApply: function (ev) {
		var self = this;
		return self.handleSave(ev).then(function () {
			var changes = uci.changes();
			var hasChanges = Object.keys(changes || {}).some(function (k) {
				return Array.isArray(changes[k]) && changes[k].length > 0;
			});
			if (!hasChanges) return;

			return uci.apply().catch(function () {}).then(function () {
				return callRestart();
			}).then(function (result) {
				if (!result || result.status === 'ok') {
					ui.addNotification(null,
						E('p', _('Configuration saved and service restarted.')),
						'info');
				} else {
					var msg = (result && result.message) ||
					          (result && result.status)  || 'unknown error';
					ui.addNotification(null,
						E('p', _('Restart failed: %s').format(String(msg))),
						'danger');
				}
			});
		});
	},

	handleApply: null,
	handleReset: null
});
