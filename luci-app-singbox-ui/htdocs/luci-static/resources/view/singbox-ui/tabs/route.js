'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';
'require view.singbox-ui.lib.view_state as SbViewState';
'require view.singbox-ui.lib.json_editor as SbJsonEditor';

var addRenameField   = SbCommon.addRenameField;
var loadOutboundList = SbCommon.loadOutboundList;

var ROUTE_RULE_TYPES = [['default', _('Default')], ['logical', _('Logical')]];
var RULE_SET_TYPES   = [['remote', _('Remote')], ['local', _('Local')], ['inline', _('Inline')]];

function toArray(v) { return (v == null) ? [] : (Array.isArray(v) ? v : [v]); }

// The built-in rule-sets' master switch. Unset means ON — mirrors
// helpers.builtin_rulesets_on() in the backend, which must agree or the grid
// shows rows the generated config does not contain.
function builtinsOn() {
	return uci.get('singbox-ui', 'main', 'default_rulesets') !== '0';
}

// Map default route_rule name -> ["logical:<name>", "inline:<name>", ...].
function consumedMap() {
	var m = {};
	uci.sections('singbox-ui', 'route_rule').forEach(function (s) {
		if ((s.type || 'default') !== 'logical') return;
		toArray(s.rules).forEach(function (n) { (m[n] = m[n] || []).push('logical:' + s['.name']); });
	});
	uci.sections('singbox-ui', 'ruleset').forEach(function (s) {
		if ((s.type || 'remote') !== 'inline') return;
		toArray(s.rules).forEach(function (n) { (m[n] = m[n] || []).push('inline:' + s['.name']); });
	});
	return m;
}

function buildRouteRulesMap() {
	var m = new form.Map('singbox-ui', _('Route Rules'),
		_('Match traffic and route, reject, sniff, resolve, or compose with logical rules. ' +
		  'Rules consumed by a logical rule or inline rule-set are not applied standalone.'));

	var s = m.section(form.GridSection, 'route_rule', null);
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) { return _('Route Rule') + ': ' + id; };

	s.tab('match', _('Match'));
	s.tab('action', _('Action'));

	addRenameField(s, 'match');
	SbJsonEditor.addJsonButtons(s, 'route_rule', form);

	var o = s.taboption('match', form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;

	o = s.taboption('match', form.ListValue, 'type', _('Type'));
	ROUTE_RULE_TYPES.forEach(function (kv) { o.value(kv[0], kv[1]); });
	o.default = 'default'; o.rmempty = false;
	// INFO-1: version-gate the route_rule type selector for symmetry with the
	// inbound/outbound selectors. No route_rule type carries a min_version
	// today, so it is a no-op — it future-proofs against a gated type being
	// silently offered with no "(requires X+)" note and no validate rejection.
	SbCommon.applyVersionGate(o,
		(SbViewState.getSchema() || {}).route_rule || {}, SbViewState.getCoreVersion(), SbViewState.getCompatOnly());

	// Read-only "Used by" badge column (grid only).
	o = s.taboption('match', form.DummyValue, '_used_by', _('Used by'));
	o.modalonly = false;
	// Memoize consumedMap() for ONE synchronous render pass: every grid row's
	// cfgvalue runs in the same tick, so compute the O(rules+rulesets) scan once
	// and serve all rows from it (was O(N) per row → O(N²) per render). Reset on
	// the next microtask so a later re-render (e.g. after Save) recomputes fresh
	// consumed relationships rather than serving a stale cache.
	var _consumedCache = null;
	o.cfgvalue = function (id) {
		if (_consumedCache === null) {
			_consumedCache = consumedMap();
			Promise.resolve().then(function () { _consumedCache = null; });
		}
		var c = _consumedCache[id];
		return c ? c.join(', ') : '';
	};

	// Descriptor-driven fields for default + logical.
	var rr = (SbViewState.getSchema() || {}).route_rule || {};
	ROUTE_RULE_TYPES.forEach(function (kv) {
		var mat = rr[kv[0]];
		if (mat) descriptor_form.applyMaterialized(s, 'route_rule', kv[0], mat);
	});

	// Validate logical sub-rules: only existing default rules, not self/logical.
	var reg = s._sbMatRegistry || {};
	var rulesEntry = reg['match\trules'];
	if (rulesEntry && rulesEntry.opt)
		rulesEntry.opt.validate = SbCommon.logicalSubRuleValidate(uci, _);

	return m;
}

function buildRuleSetsMap() {
	var m = new form.Map('singbox-ui', _('Rule-Sets'),
		_('Remote (.srs/.json), local, or inline rule-sets referenced by route rules.'));

	var s = m.section(form.GridSection, 'ruleset', null);
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) { return _('Rule-Set') + ': ' + id; };
	SbCommon.lockBuiltinRow(s,
		_('Built-in rule-set — managed by the package. Toggle Enable, or turn the whole set off in General.'),
		function () { return !builtinsOn(); });

	s.tab('basic', _('Basic'));

	addRenameField(s, 'basic');
	SbJsonEditor.addJsonButtons(s, 'ruleset', form);

	var o = s.taboption('basic', form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;

	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	RULE_SET_TYPES.forEach(function (kv) { o.value(kv[0], kv[1]); });
	o.default = 'remote'; o.rmempty = false;

	var rs = (SbViewState.getSchema() || {}).rule_set || {};
	// INFO-1: version-gate the rule_set type selector (no-op today; symmetry).
	SbCommon.applyVersionGate(o, rs, SbViewState.getCoreVersion(), SbViewState.getCompatOnly());
	RULE_SET_TYPES.forEach(function (kv) {
		var mat = rs[kv[0]];
		if (mat) descriptor_form.applyMaterialized(s, 'rule_set', kv[0], mat);
	});

	return m;
}

function buildRouteDefaultMap() {
	var m = new form.Map('singbox-ui', _('Default'),
		_('Final route applied to traffic that does not match any rule.'));

	var s = m.section(form.NamedSection, 'route_default', 'route_default', _('Default'));
	s.anonymous = true;

	var o = s.option(form.ListValue, 'action', _('Action'));
	o.value('route',  _('Route'));
	o.value('bypass', _('Bypass'));
	o.value('reject', _('Reject'));
	o.default = 'route';
	o.description = _('Bypass leaves the connection to the kernel — but only for auto-redirect (TUN) traffic, which this package does not use. With an outbound set it behaves exactly like Route; without one the rule is skipped.');
	// bypass landed in sing-box 1.13. applyVersionGate takes any {value: {min_version}}
	// map, so the route_default selector gets the same "(requires 1.13+)" disable +
	// validate rejection the descriptor-driven selectors get — an older core would
	// otherwise be handed an action it fatally rejects at load.
	SbCommon.applyVersionGate(o, { bypass: { min_version: '1.13' } },
		SbViewState.getCoreVersion(), SbViewState.getCompatOnly());

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'route');
	o.depends('action', 'bypass');
	// (none) is a real choice for bypass — sing-box reads it as `"outbound": ""`.
	// For action=route it is not: route.uc drops a final with no outbound.
	loadOutboundList(o, true);
	o.default = 'wan';

	return m;
}

return L.Class.extend({
	buildRouteRulesMap:   buildRouteRulesMap,
	buildRuleSetsMap:     buildRuleSetsMap,
	buildRouteDefaultMap: buildRouteDefaultMap,
	builtinsOn:           builtinsOn,
});
