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
	  pkg: 'singbox-ui-plugin-awg_warp',
	  description: _('Adds a Cloudflare WARP egress obfuscated with AmneziaWG.') },
];

function buildPluginsMap() {
	// Use the RAW plugins list (listAll), NOT loadEnabled(): "installed" must
	// reflect that the package is on disk (present in the registry), independent
	// of the "enabled" UCI flag. Driving "installed" off the enabled-only list
	// made the Enable button permanently unreachable for a freshly installed
	// plugin (it reports enabled:false until you enable it).
	return SbPlugins.listAll().then(function (raw) {
		var status = SbPlugins.pluginStatusMap(raw);

		var m = new form.Map('singbox-ui', _('Plugins'),
			_('Optional feature plugins. Each plugin is a separate package from this feed; ' +
			  'some pull additional system components on first setup.'));
		var s = m.section(form.TypedSection, '_plugins');
		s.anonymous = true;
		s.render = function () {
			var rows = KNOWN.map(function (k) {
				var st = status[k.name] || { installed: false, enabled: false };
				var isInstalled = !!st.installed;
				var isEnabled = !!st.enabled;
				var installBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isInstalled ? 'disabled' : null,
					'click': ui.createHandlerFn(this, function () {
						return callInstall(k.pkg).then(function () {
							ui.addNotification(null, E('p', _('Installed. Reload the page.')), 'info');
						});
					}),
				}, isInstalled ? _('Installed') : _('Install'));
				// Enable is reachable once installed; it toggles the UCI flag so
				// the plugin can also be disabled without removing the package.
				var enableBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isInstalled ? null : 'disabled',
					'click': ui.createHandlerFn(this, function () {
						return callEnable(k.name, !isEnabled).then(function () {
							ui.addNotification(null, E('p',
								isEnabled ? _('Disabled. Reload the page.')
								          : _('Enabled. Reload the page.')), 'info');
						});
					}),
				}, isEnabled ? _('Disable') : _('Enable'));
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
