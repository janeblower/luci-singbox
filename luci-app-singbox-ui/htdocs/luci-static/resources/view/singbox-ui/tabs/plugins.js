'use strict';
'require form';
'require rpc';
'require ui';
'require view.singbox-ui.lib.plugins as SbPlugins';

var callInstall = rpc.declare({ object: 'singbox-ui', method: 'plugin_install', params: ['package'] });

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
				var installBtn = E('button', {
					'class': 'cbi-button cbi-button-action',
					'disabled': isInstalled ? 'disabled' : null,
					'click': ui.createHandlerFn(this, function () {
						return callInstall(k.pkg).then(function () {
							ui.addNotification(null, E('p', _('Installed. Reload the page.')), 'info');
						});
					}),
				}, isInstalled ? _('Installed') : _('Install'));
				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td' }, [ E('strong', {}, [k.label]), E('br'), k.description ]),
					E('td', { 'class': 'td' }, [ installBtn ]),
				]);
			});
			return E('div', { 'class': 'cbi-section' }, [
				E('table', { 'class': 'table' }, rows),
			]);
		};

		// Enable/disable is a PLAIN UCI FLAG on the `plugins` section, not an RPC
		// button. The button called plugin_enable, whose handler did a bare
		// cursor.commit("singbox-ui") — that flushes the WHOLE package, including
		// a delta someone else staged. Edit an inbound, Save (not Apply), switch
		// to this tab, hit Enable: the staged edit was committed to /etc/config
		// without an Apply and Revert no longer worked. It was also a raw commit
		// rather than `ubus uci apply`, so the procd trigger never fired and the
		// plugin did not reach the daemon until cron or a reboot — hence the
		// toast could only say "reload the page".
		//
		// As a Flag on the map, Save & Apply, the procd reload and Revert all
		// work by themselves, and nothing commits anyone else's staging.
		var ps = m.section(form.NamedSection, 'plugins', 'singbox-ui',
			_('Enabled plugins'));
		KNOWN.forEach(function (k) {
			var st = status[k.name] || { installed: false };
			var o = ps.option(form.Flag, k.name + '_enabled', k.label, k.description);
			o.rmempty = false;
			o.default = '0';
			if (!st.installed) {
				o.readonly = true;
				o.description = _('Not installed.');
			}
		});
		return m;
	});
}

return L.Class.extend({ buildPluginsMap: buildPluginsMap });
