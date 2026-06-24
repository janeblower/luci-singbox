'use strict';
'require form';
'require rpc';
'require ui';
'require view.singbox-ui.lib.plugins as SbPlugins';

var callInstall = rpc.declare({ object: 'singbox-ui', method: 'plugin_install', params: ['package'] });
var callEnable = rpc.declare({ object: 'singbox-ui', method: 'plugin_enable', params: ['name', 'enabled'] });

// Available plugins live in OUR feed by naming convention. v1 surfaces them via
// a small static list; installed ones come from the `plugins` rpcd method.
var KNOWN = [
	{ name: 'awg_warp', label: _('AWG WARP (Cloudflare WARP + AmneziaWG)'),
	  pkg: 'luci-app-singbox-plugin-awg-warp',
	  description: _('Adds a Cloudflare WARP egress obfuscated with AmneziaWG.') },
];

function buildPluginsMap() {
	return SbPlugins.loadEnabled().then(function (loaded) {
		var installed = {};
		(loaded || []).forEach(function (p) { installed[p.name] = true; });

		var m = new form.Map('singbox-ui', _('Plugins'),
			_('Optional feature plugins. Each plugin is a separate package from this feed; ' +
			  'some pull additional system components on first setup.'));
		var s = m.section(form.TypedSection, '_plugins');
		s.anonymous = true;
		s.render = function () {
			var rows = KNOWN.map(function (k) {
				var isInstalled = !!installed[k.name];
				var installBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isInstalled ? 'disabled' : null,
					'click': ui.createHandlerFn(this, function () {
						return callInstall(k.pkg).then(function () {
							ui.addNotification(null, E('p', _('Installed. Reload the page.')), 'info');
						});
					}),
				}, isInstalled ? _('Installed') : _('Install'));
				var enableBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isInstalled ? null : 'disabled',
					'click': ui.createHandlerFn(this, function () {
						return callEnable(k.name, true).then(function () {
							ui.addNotification(null, E('p', _('Enabled. Reload the page.')), 'info');
						});
					}),
				}, _('Enable'));
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ E('strong', {}, k.label), E('br'), k.description ]),
					E('td', { 'class': 'td' }, [ installBtn, ' ', enableBtn ]),
				]);
			});
			return E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, rows),
			]);
		};
		return m;
	});
}

return L.Class.extend({ buildPluginsMap: buildPluginsMap });
