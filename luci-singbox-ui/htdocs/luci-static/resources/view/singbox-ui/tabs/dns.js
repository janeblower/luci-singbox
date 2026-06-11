'use strict';
'require form';
'require uci';
'require view.singbox-ui.lib.common as SbCommon';

var addRenameField   = SbCommon.addRenameField;
var loadOutboundList = SbCommon.loadOutboundList;

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
		_('DNS servers (udp/tls/https/fakeip), rules, and global settings.'));
	var s, o;

	// -- Servers --
	s = m.section(form.GridSection, 'dns_server', _('DNS Servers'));
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) {
		var t = uci.get('singbox-ui', id, 'type') || '';
		return _('DNS Server') + ': ' + id + (t ? ' (' + t + ')' : '');
	};
	addRenameField(s);
	o = s.option(form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;
	o = s.option(form.ListValue, 'type', _('Type'));
	['udp','tls','https','fakeip'].forEach(function (v) { o.value(v, v); });
	o.default = 'https'; o.rmempty = false;
	o = s.option(form.Value, 'server', _('Server')); o.modalonly = true;
	o.depends('type','udp'); o.depends('type','tls'); o.depends('type','https');
	o = s.option(form.Value, 'server_port', _('Server port')); o.modalonly = true; o.datatype = 'port';
	o.depends('type','udp'); o.depends('type','tls'); o.depends('type','https');
	o = s.option(form.Value, 'path', _('HTTPS path')); o.modalonly = true; o.placeholder = '/dns-query';
	o.depends('type','https');
	// Pinning a DNS query to a specific outbound. Dropdown of user-defined
	// outbound tags only — the auto-injected implicit `direct` is intentionally
	// not selectable because sing-box 1.12 rejects detour to a field-less
	// direct outbound at startup. Leave empty to let route rules decide.
	o = s.option(form.ListValue, 'detour', _('Detour (outbound)'));
	o.modalonly = true;
	loadOutboundList(o, true);
	o.depends('type','udp'); o.depends('type','tls'); o.depends('type','https');
	// Resolver used for this server's own domain — points at another DNS
	// server tag. Dropdown of defined dns_server sections (+ none) instead of
	// a free-text tag the user has to copy by hand.
	o = s.option(form.ListValue, 'domain_resolver', _('Domain resolver')); o.modalonly = true;
	loadDnsServerList(o, true);
	o.depends('type','udp'); o.depends('type','tls'); o.depends('type','https');
	o = s.option(form.Value, 'inet4_range', _('FakeIP IPv4 range')); o.modalonly = true;
	o.datatype = 'cidr4'; o.placeholder = '198.18.0.0/15'; o.depends('type','fakeip');
	o = s.option(form.Value, 'inet6_range', _('FakeIP IPv6 range')); o.modalonly = true;
	o.datatype = 'cidr6'; o.placeholder = 'fc00::/18'; o.depends('type','fakeip');

	// -- Rules --
	s = m.section(form.GridSection, 'dns_rule', _('DNS Rules'));
	s.anonymous = false; s.addremove = true; s.sortable = true;
	s.modaltitle = function (id) { return _('DNS Rule') + ': ' + id; };
	addRenameField(s);
	o = s.option(form.Flag, 'enabled', _('Enable')); o.default = '1'; o.editable = true;
	o = s.option(form.MultiValue, 'ruleset', _('Rule-Sets'));
	o.load = function (section_id) {
		this.keylist = []; this.vallist = [];
		uci.sections('singbox-ui', 'ruleset').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.MultiValue.prototype.load.apply(this, arguments);
	};
	o = s.option(form.Value, 'domain_suffix', _('Domain suffix (comma-separated)')); o.modalonly = true;
	o = s.option(form.Value, 'domain_keyword', _('Domain keyword (comma-separated)')); o.modalonly = true;
	o = s.option(form.ListValue, 'clash_mode', _('Clash mode'));
	[['','any'],['global','global'],['direct','direct'],['rule','rule']].forEach(function (p) {
		o.value(p[0], p[1] === 'any' ? _('Any') : p[1]);
	});
	o.modalonly = true;
	o = s.option(form.ListValue, 'server', _('Target server')); loadDnsServerList(o);
	o = s.option(form.Value, 'rewrite_ttl', _('Rewrite TTL (s)'));
	o.modalonly  = true;
	o.datatype   = 'uinteger';
	o.placeholder = '60';
	o.default    = '60';
	o.description = _('Forces this TTL on responses matched by the rule. ' +
	                  '0 disables rewriting. Default is 60.');

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
