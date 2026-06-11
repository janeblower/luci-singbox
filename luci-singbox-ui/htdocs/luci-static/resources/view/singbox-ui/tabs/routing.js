'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';

var addRenameField   = SbCommon.addRenameField;
var loadOutboundList = SbCommon.loadOutboundList;

function buildRouteRulesMap() {
	var m = new form.Map('singbox-ui', _('Route Rules'),
		_('Match traffic against one or more rule-sets and send it to an outbound, direct, or block.'));

	var s = m.section(form.GridSection, 'route_rule', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) { return _('Route Rule') + ': ' + section_id; };
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.MultiValue, 'ruleset', _('Rule-Sets'));
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		uci.sections('singbox-ui', 'ruleset').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.MultiValue.prototype.load.apply(this, arguments);
	};

	o = s.option(form.ListValue, 'action', _('Action'));
	o.value('direct',   _('Direct'));
	o.value('block',    _('Block'));
	o.value('outbound', _('Outbound'));
	o.default = 'direct';
	o.rmempty = false;

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'outbound');
	loadOutboundList(o);

	return m;
}

function buildRouteDefaultMap() {
	var m = new form.Map('singbox-ui', _('Default'),
		_('Final route applied to traffic that does not match any rule.'));

	var s = m.section(form.NamedSection, 'route_default', 'route_default', _('Default'));
	s.anonymous = true;

	var o;
	o = s.option(form.ListValue, 'action', _('Action'));
	o.value('direct',   _('Direct'));
	o.value('block',    _('Block'));
	o.value('outbound', _('Outbound'));
	o.default = 'direct';

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'outbound');
	loadOutboundList(o);

	return m;
}

return L.Class.extend({
	buildRouteRulesMap:   buildRouteRulesMap,
	buildRouteDefaultMap: buildRouteDefaultMap,
});
