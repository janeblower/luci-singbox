'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';
'require view.singbox-ui.lib.view_state as SbViewState';

var addRenameField   = SbCommon.addRenameField;
var loadOutboundList = SbCommon.loadOutboundList;

var ROUTE_RULE_TYPES = [['default', _('Default')], ['logical', _('Logical')]];
var RULE_SET_TYPES   = [['remote', _('Remote')], ['local', _('Local')], ['inline', _('Inline')]];

function toArray(v) { return (v == null) ? [] : (Array.isArray(v) ? v : [v]); }

// Built-in rule-sets (itdoginfo/allow-domains, seeded by uci-defaults) carry
// `builtin '1'`. They are ordinary UCI sections — the package owns their url and
// name, so the UI refuses to edit or delete them — but `enabled` stays a normal
// per-row toggle: turning the ones you want on is the whole point of shipping 25.
function isBuiltin(sid) { return uci.get('singbox-ui', sid, 'builtin') === '1'; }

// The master switch. Unset means ON — mirrors helpers.builtin_rulesets_on() in
// the backend, which must agree or the grid and the generated config diverge.
function builtinsOn() {
	return uci.get('singbox-ui', 'main', 'default_rulesets') !== '0';
}

// Make a grid row read-only: keep LuCI's own action cell (so the layout and the
// drag handle stay intact) but disable the buttons that mutate the section.
// `disabled` is what greys them out — no extra CSS needed for that part.
function lockBuiltinRow(s, note) {
	var origFilter = s.filter;
	s.filter = function (section_id) {
		if (isBuiltin(section_id) && !builtinsOn()) return false;
		return origFilter ? origFilter.apply(this, arguments) : true;
	};

	var origRowActions = s.renderRowActions;
	s.renderRowActions = function (section_id, more_label, trEl) {
		var td = origRowActions.apply(this, arguments);
		if (!isBuiltin(section_id)) return td;
		if (trEl && trEl.classList) trEl.classList.add('sb-builtin-row');
		if (td && td.querySelectorAll)
			td.querySelectorAll('button').forEach(function (b) {
				// The drag handle only reorders; it mutates nothing the package owns.
				if (b.classList && b.classList.contains('drag-handle')) return;
				b.disabled = true;
				b.title = note;
			});
		return td;
	};
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
	lockBuiltinRow(s, _('Built-in rule-set — managed by the package. Toggle Enable, or turn the whole set off in General.'));

	s.tab('basic', _('Basic'));

	addRenameField(s, 'basic');

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
	o.value('route', _('Route')); o.value('reject', _('Reject'));
	o.default = 'route';

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'route');
	loadOutboundList(o);

	return m;
}

return L.Class.extend({
	buildRouteRulesMap:   buildRouteRulesMap,
	buildRuleSetsMap:     buildRuleSetsMap,
	buildRouteDefaultMap: buildRouteDefaultMap,
	isBuiltin:            isBuiltin,
	builtinsOn:           builtinsOn,
	lockBuiltinRow:       lockBuiltinRow,
});
