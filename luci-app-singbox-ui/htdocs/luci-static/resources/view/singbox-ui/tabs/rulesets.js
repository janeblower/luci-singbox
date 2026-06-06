'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';

var addRenameField = SbCommon.addRenameField;

function buildRulesetsMap() {
	var m = new form.Map('singbox-ui', _('Rule-Sets'),
		_('Remote (.srs/.json) or local rule-sets, referenced by route rules.'));

	var s = m.section(form.GridSection, 'ruleset', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) { return _('Rule-Set') + ': ' + section_id; };
	addRenameField(s);

	var o;
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

	// Format is auto-detected from the file extension by subscription.uc
	// and generate.uc (.srs → binary, .json → source). No UI field.

	o = s.option(form.Flag, 'nft_rules', _('Create nftables rules'));
	o.modalonly = true;
	o.default   = '0';

	o = s.option(form.Value, 'update_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '86400';
	o.depends('type', 'remote');

	return m;
}

return L.Class.extend({ buildRulesetsMap: buildRulesetsMap });
