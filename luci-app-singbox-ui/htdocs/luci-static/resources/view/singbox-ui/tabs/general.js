'use strict';
'require form';
'require uci';

function buildGeneralMap() {
	var m = new form.Map('singbox-ui', _('General'),
		_('Global sing-box settings: cache file, log.'));

	var s, o;

	// --- Cache file ---
	s = m.section(form.NamedSection, 'cache', 'cache', _('Cache file'),
		_('Persistent cache for proxies, DNS responses, and fakeip mappings.'));

	o = s.option(form.Flag, 'enabled', _('Enable cache file'));
	o.default = '1';

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

	return m;
}

return L.Class.extend({ buildGeneralMap: buildGeneralMap });
