'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';
'require view.singbox-ui.lib.view_state as SbViewState';

var addRenameField = SbCommon.addRenameField;

// All 14 DNS server types with display labels.
var DNS_SERVER_TYPES = [
	['udp',        'UDP'],
	['tcp',        'TCP'],
	['tls',        'DNS-over-TLS'],
	['quic',       'DNS-over-QUIC'],
	['https',      'DNS-over-HTTPS'],
	['h3',         'DNS-over-HTTP/3'],
	['fakeip',     'FakeIP'],
	['local',      _('Local system')],
	['hosts',      _('Hosts file')],
	['dhcp',       'DHCP'],
	['mdns',       'mDNS'],
	['tailscale',  'Tailscale'],
	['resolved',   'systemd-resolved'],
	['legacy',     _('Legacy (address string)')],
];

function loadDnsServerList(o, includeNone) {
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		if (includeNone) this.value('', _('(none)'));
		uci.sections('singbox-ui', 'dns_server').forEach(function (sec) {
			this.value(sec['.name'], sec['.name'] + ' (' + (sec.type || '?') + ')');
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};
}

function buildDnsMap() {
	var m = new form.Map('singbox-ui', _('DNS'),
		_('DNS servers, rules, and global settings.'));
	var s, o;

	// -- Servers --
	s = m.section(form.GridSection, 'dns_server', _('DNS Servers'));
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) {
		var t = uci.get('singbox-ui', id, 'type') || '';
		return _('DNS Server') + ': ' + id + (t ? ' (' + t + ')' : '');
	};
	addRenameField(s);
	var dnsSchema = (SbViewState.getSchema() || {}).dns || {};
	// Declare the 'basic' tab up front and route the discriminator fields
	// (enabled/type) through it, mirroring inbounds.js/outbounds.js. Otherwise
	// enabled/type render in the untabbed section header while every descriptor
	// field (applyMaterialized routes through s.taboption('basic', ...)) lives
	// in a 'basic' tab pane — a split-region modal (UX-1). applyMaterialized's
	// tab guard probes s.tabs and skips re-declaring 'basic', so this is safe.
	s.tab('basic', _('Basic'));
	o = s.taboption('basic', form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;
	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	DNS_SERVER_TYPES.forEach(function (kv) { o.value(kv[0], kv[1]); });
	o.default = 'https'; o.rmempty = false;
	// INFO-1: version-gate the DNS server type selector for symmetry with
	// inbounds/outbounds. No DNS type carries a min_version today, so this is a
	// no-op now; it prevents a future silent gap where a gated DNS type would be
	// offered with no "(requires X+)" note and no validate rejection.
	SbCommon.applyVersionGate(o, dnsSchema, SbViewState.getCoreVersion(), SbViewState.getCompatOnly());

	// Descriptor-driven fields for all 14 DNS server types.
	// applyMaterialized(s, 'dns', typeName, mat) gates every field from the
	// descriptor with depends({type: typeName}) — same mechanism as outbounds —
	// because kind='dns' resolves the discriminator field to 'type'.
	DNS_SERVER_TYPES.forEach(function (kv) {
		var typeName = kv[0];
		var mat = dnsSchema[typeName];
		if (mat) descriptor_form.applyMaterialized(s, 'dns', typeName, mat);
	});

	// -- Rules (descriptor-driven: default + logical) --
	s = m.section(form.GridSection, 'dns_rule', _('DNS Rules'));
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) { return _('DNS Rule') + ': ' + id; };
	addRenameField(s);
	o = s.option(form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;
	o = s.option(form.ListValue, 'type', _('Type'));
	o.value('default', _('Default')); o.value('logical', _('Logical'));
	o.default = 'default'; o.modalonly = true;
	// INFO-1: version-gate the dns_rule type selector for symmetry with
	// inbounds/outbounds/route_rule. No dns_rule type carries a min_version
	// today, so it is a no-op — future-proofs against a gated type being
	// silently offered with no "(requires X+)" note and no validate rejection.
	SbCommon.applyVersionGate(o,
		(SbViewState.getSchema() || {}).dns_rule || {}, SbViewState.getCoreVersion(), SbViewState.getCompatOnly());
	var dnsRuleSchema = (SbViewState.getSchema() || {}).dns_rule || {};
	['default', 'logical'].forEach(function (tn) {
		var mat = dnsRuleSchema[tn];
		if (mat) descriptor_form.applyMaterialized(s, 'dns_rule', tn, mat);
	});

	// -- Settings --
	s = m.section(form.NamedSection, 'dns', 'dns', _('DNS Settings'));
	s.anonymous = true;
	o = s.option(form.ListValue, 'final', _('Final server')); loadDnsServerList(o, true);
	// Picked up by generate.uc as route.default_domain_resolver. If left
	// empty, the first non-fakeip dns_server is auto-selected. Without it,
	// sing-box 1.12 emits a deprecation warning and 1.14 will refuse the
	// config.
	o = s.option(form.ListValue, 'default_resolver',
		_('Default domain resolver (bootstrap)'));
	loadDnsServerList(o, true);
	o = s.option(form.ListValue, 'strategy', _('Strategy'));
	[['','default'],['prefer_ipv4','prefer_ipv4'],['prefer_ipv6','prefer_ipv6'],
	 ['ipv4_only','ipv4_only'],['ipv6_only','ipv6_only']].forEach(function (p) {
		o.value(p[0], p[1] === 'default' ? _('Default') : p[1]);
	});
	o = s.option(form.Flag, 'independent_cache', _('Independent cache')); o.default = '0';

	return m;
}

return L.Class.extend({
	loadDnsServerList: loadDnsServerList,
	buildDnsMap:       buildDnsMap,
});
