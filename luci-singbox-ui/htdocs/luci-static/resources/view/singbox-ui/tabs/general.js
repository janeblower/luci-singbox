'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';
'require view.singbox-ui.lib.view_state as SbViewState';

function buildGeneralMap() {
	var m = new form.Map('singbox-ui', _('General'),
		_('Global sing-box settings: cache file, log.'));

	var s, o;

	// --- UI preferences ---
	s = m.section(form.NamedSection, 'main', 'singbox-ui', _('UI preferences'));
	o = s.option(form.Flag, 'ui_compat_only',
		_('Show only parameters compatible with the installed sing-box version'));
	o.default = '0';
	o.rmempty = false;
	o.description = _('When on, version-incompatible fields are hidden instead of shown disabled. Takes effect after save/reload.');

	// --- Cache file ---
	s = m.section(form.NamedSection, 'cache', 'cache', _('Cache file'),
		_('Persistent cache for proxies, DNS responses, and fakeip mappings.'));

	o = s.option(form.Flag, 'enabled', _('Enable cache file'));
	o.default = '1';
	// rmempty=false: LuCI drops a Flag from UCI when its value equals the
	// default ('1'), so a checked-but-default cache toggle silently lost
	// `enabled` on save. cache.uc gates on `enabled === "1"`, so the cache_file
	// block then vanished from the generated config (and with it the nft/bbolt
	// rule-set path). Persist the option unconditionally.
	o.rmempty = false;

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
	o.rmempty = false;   // same default-stripping footgun as `enabled` above
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

	// --- Clash API (descriptor-driven; drives the Dashboard tab) ---
	s = m.section(form.NamedSection, 'clash_api', 'clash_api', _('Clash API'),
		_('Enables sing-box experimental.clash_api. Required by the Dashboard tab. ' +
		  'Restart the service after changing.'));
	var clashSchema = (SbViewState.getSchema() || {}).clash_api || {};
	if (clashSchema.clash_api)
		descriptor_form.applyMaterializedNamed(s, 'clash_api', 'clash_api', clashSchema.clash_api);

	// --- Subscriptions ---
	s = m.section(form.NamedSection, 'subscriptions', 'subscriptions', _('Subscriptions'));
	o = s.option(form.Flag, 'auto_update', _('Auto-update subscriptions'));
	o.default = '1';
	o.description = _('Periodically refresh subscriptions via cron (each sub honors its own update interval).');

	return m;
}

return L.Class.extend({ buildGeneralMap: buildGeneralMap });
