'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require network';

// rpcd binding: singbox-ui restart
var callRestart = rpc.declare({
	object: 'singbox-ui',
	method: 'restart'
});

return view.extend({
	load: function () {
		return Promise.all([
			network.getDevices(),
			uci.load('singbox-ui')
		]);
	},

	render: function (data) {
		var self = this;
		var devices = data[0];

		// ---- Input form ----
		var mInput = new form.Map('singbox-ui', _('Input'),
			_('Configure FakeIP and TProxy inbound. ' +
			  'nftables redirect rules are applied automatically ' +
			  'when TProxy is enabled and the service starts.'));

		var s, o;

		// FakeIP
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

		// TProxy
		s = mInput.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.ListValue, 'interface', _('Interface'));
		(devices || []).forEach(function (d) {
			var name = d.getName();
			if (name) o.value(name, name);
		});

		o = s.option(form.Value, 'port', _('Port'));
		o.datatype = 'port';
		o.placeholder = '7893';

		// ---- Output form ----
		var mOutput = new form.Map('singbox-ui', _('Output'),
			_('Add, configure, and remove outbounds. ' +
			  'Each outbound can have routing conditions (rule sets and domains).'));

		s = mOutput.section(form.TypedSection, 'outbound', _('Outbounds'));
		s.anonymous = false;
		s.addremove = true;

		s.tab('settings', _('Settings'));
		s.tab('conditions', _('Conditions'));

		o = s.taboption('settings', form.ListValue, 'action', _('Action'));
		o.value('direct', _('Direct'));
		o.value('block', _('Block'));
		o.value('proxy', _('Proxy'));
		o.rmempty = false;

		o = s.taboption('settings', form.ListValue, 'proxy_type', _('Type'));
		o.value('interface', _('Interface'));
		o.value('url', _('URL (share link)'));
		o.depends('action', 'proxy');

		o = s.taboption('settings', form.ListValue, 'interface', _('Interface'));
		(devices || []).forEach(function (d) {
			var name = d.getName();
			if (name) o.value(name, name);
		});
		o.depends({ action: 'proxy', proxy_type: 'interface' });

		o = s.taboption('settings', form.Value, 'proxy_url', _('URL'));
		o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
		o.depends({ action: 'proxy', proxy_type: 'url' });

		o = s.taboption('conditions', form.DynamicList, 'ruleset', _('Rule sets'));
		o.placeholder = 'https://example.com/geosite.srs  or  /etc/singbox-ui/rules.json';

		o = s.taboption('conditions', form.DynamicList, 'domain', _('Domains'));
		o.placeholder = 'example.com';

		self._mInput  = mInput;
		self._mOutput = mOutput;

		return Promise.all([ mInput.render(), mOutput.render() ]).then(function (nodes) {
			var inputNode  = nodes[0];
			var outputNode = nodes[1];

			outputNode.style.display = 'none';

			function switchTab(ev) {
				var tab = ev.currentTarget.getAttribute('data-tab');
				document.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.classList.toggle('cbi-tab-active', el.getAttribute('data-tab') === tab);
				});
				inputNode.style.display  = (tab === 'input')  ? '' : 'none';
				outputNode.style.display = (tab === 'output') ? '' : 'none';
			}

			return E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', {
						'class': 'cbi-tab-active',
						'data-tab': 'input',
						'click': switchTab
					}, _('Input')),
					E('li', {
						'class': 'cbi-tab',
						'data-tab': 'output',
						'click': switchTab
					}, _('Output'))
				]),
				inputNode,
				outputNode
			]);
		});
	},

	handleSave: function (ev) {
		return Promise.all([
			this._mInput.save(),
			this._mOutput.save()
		]);
	},

	handleSaveApply: function (ev) {
		var self = this;
		return self.handleSave(ev).then(function () {
			return callRestart().then(function (result) {
				if (!result || result.status === 'ok') {
					ui.addNotification(null,
						E('p', _('Service restarted successfully.')),
						'info');
				} else {
					var msg = (result && result.message) || (result && result.status) || 'unknown error';
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
