'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require ui';
'require network';

// rpcd binding: sing-box.generate
var callGenerate = rpc.declare({
	object: 'sing-box',
	method: 'generate',
	expect: { status: 'error' }
});

// rpcd binding: sing-box.nftables
var callNftables = rpc.declare({
	object: 'sing-box',
	method: 'nftables',
	params: [ 'action' ],
	expect: { status: 'error' }
});

function syncNftables(prevEnabled, nextEnabled) {
	if (prevEnabled === nextEnabled) return Promise.resolve();
	var action = nextEnabled ? 'apply' : 'remove';
	return callNftables(action).then(function (status) {
		// expect:{status:'error'} returns the value of the `status` key, falling
		// back to the literal 'error' if the key is missing. So 'ok' is success
		// and anything else is failure.
		if (status && status !== 'ok') {
			ui.addNotification(null,
				E('p', _('nftables %s failed: %s').format(action, String(status))),
				'danger');
		}
	});
}

return view.extend({
	load: function () {
		return Promise.all([
			network.getDevices(),
			uci.load('sing-box')
		]);
	},

	render: function (data) {
		var devices = data[0];
		var prevNftEnabled = uci.get('sing-box', 'nftables', 'enabled') === '1';

		var m, s, o;

		m = new form.Map('sing-box', _('Sing-Box'),
			_('Configure FakeIP, TProxy inbound, and nftables redirect rules. ' +
			  'Use the Generate Config button to write /tmp/sing-box.json.'));

		// --- FakeIP ---
		s = m.section(form.NamedSection, 'fakeip', 'fakeip', _('FakeIP'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		o = s.option(form.DynamicList, 'inet4_range', _('IPv4 ranges'));
		o.datatype = 'cidr4';
		o.placeholder = '198.18.0.0/15';

		o = s.option(form.DynamicList, 'inet6_range', _('IPv6 ranges'));
		o.datatype = 'cidr6';
		o.placeholder = 'fc00::/18';

		// --- TProxy Inbound ---
		s = m.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
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

		// --- nftables ---
		s = m.section(form.NamedSection, 'nftables', 'nftables', _('nftables'),
			_('Apply the redirect rules required to send FakeIP traffic to ' +
			  'the TProxy inbound. Toggling this flag invokes apply or remove ' +
			  'on save.'));
		s.anonymous = true;

		o = s.option(form.Flag, 'enabled', _('Enable'));
		o.rmempty = false;

		// Hook the post-save step: act on the new nftables.enabled value.
		m.onSaveAfter = function () {
			var nextEnabled = uci.get('sing-box', 'nftables', 'enabled') === '1';
			return syncNftables(prevNftEnabled, nextEnabled).then(function () {
				prevNftEnabled = nextEnabled;
			});
		};

		// --- Generate Config button (outside the form) ---
		var generateBtn = E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				return callGenerate().then(function (status) {
					if (!status || status === 'ok') {
						ui.addNotification(null,
							E('p', _('sing-box config written to /tmp/sing-box.json')),
							'info');
					} else {
						ui.addNotification(null,
							E('p', _('Generate failed: %s').format(String(status))),
							'danger');
					}
				});
			})
		}, _('Generate Config'));

		return m.render().then(function (mapNode) {
			return E([], [
				mapNode,
				E('div', { 'class': 'cbi-page-actions', 'style': 'margin-top:1em' },
					generateBtn)
			]);
		});
	},

	handleSaveApply: null,
	handleApply: null,
	handleReset: null
});
