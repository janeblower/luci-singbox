'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';
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

	o = s.option(form.Flag, 'default_rulesets', _('Enable default rule-sets'));
	o.default = '1';
	o.rmempty = false;
	o.description = _('Ship the itdoginfo/allow-domains rule-sets as read-only entries in the Rule-Sets tab. When off they are hidden and never referenced, fetched, or written to the config.');

	// One shared download detour for ALL built-in rule-sets. They all fetch from
	// the same github release, so this is the knob for "github is blocked, pull
	// them through a proxy" — one selector instead of 25. Applies only to built-in
	// remote sets that have no detour of their own (backend: ruleset.uc).
	o = s.option(form.ListValue, 'default_ruleset_detour',
		_('Built-in rule-set download detour'));
	o.depends('default_rulesets', '1');
	o.description = _('Fetch the built-in rule-sets through this outbound (e.g. when their host is blocked). Leave as (none) to download them directly.');
	SbCommon.loadOutboundList(o, true);

	// --- Cache file (descriptor-driven) ---
	s = m.section(form.NamedSection, 'cache', 'cache', _('Cache file'),
		_('Persistent cache for proxies, DNS responses, and fakeip mappings.'));
	var cacheSchema = (SbViewState.getSchema() || {}).cache || {};
	if (cacheSchema.cache)
		descriptor_form.applyMaterializedNamed(s, 'cache', 'cache', cacheSchema.cache);

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
