'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require tools.widgets as widgets';

var callRefresh    = rpc.declare({ object: 'singbox-ui', method: 'refresh',     params: [ 'what' ] });
var callRestart    = rpc.declare({ object: 'singbox-ui', method: 'restart' });
var callStatus     = rpc.declare({ object: 'singbox-ui', method: 'status' });
var callReadConfig = rpc.declare({ object: 'singbox-ui', method: 'read_config' });

// Insert a synthetic "Name" field as the first option of a GridSection's
// edit modal. cfgvalue returns the section id, write triggers uci.rename.
// We don't write a real UCI option; remove() is a no-op for the same reason.
// loadOutboundList(o) — populate an `outbound` ListValue with the current
// UCI outbound section names. Shared between route_rule and route_default.
function loadOutboundList(o) {
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};
}

function addRenameField(s) {
	var o = s.option(form.Value, '__rename', _('Name'));
	o.modalonly = true;
	o.rmempty   = false;
	o.datatype  = 'and(minlength(1), uciname)';
	o.cfgvalue  = function (section_id) { return section_id; };
	o.write     = function (section_id, value) {
		if (value && value !== section_id)
			uci.rename('singbox-ui', section_id, value);
	};
	o.remove = function () {};
}

var SB_INBOUND_PROTOCOLS = [
	['tproxy',      'TProxy (transparent)'],
	['tun',         'TUN'],
	['shadowsocks', 'Shadowsocks'],
	['vless',       'VLESS'],
	['vmess',       'VMess'],
	['trojan',      'Trojan'],
	['hysteria2',   'Hysteria2']
];

function buildInboundsMap() {
	var m = new form.Map('singbox-ui', _('Inbounds'),
		_('Define inbounds: raw JSON or a per-protocol constructor. ' +
		  'nftables rules are applied for tproxy/tun inbounds that request them.'));

	var s = m.section(form.GridSection, 'inbound', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) {
		var p = uci.get('singbox-ui', section_id, 'protocol') || '';
		return _('Inbound') + ': ' + section_id + (p ? ' (' + p + ')' : '');
	};
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default = '1'; o.editable = true;

	o = s.option(form.ListValue, 'mode', _('Mode'));
	o.value('constructor', _('Constructor'));
	o.value('json',        _('Raw JSON'));
	o.default = 'constructor'; o.rmempty = false;

	o = s.option(form.TextValue, 'inbound_json', _('Inbound JSON'));
	o.modalonly = true; o.rows = 6; o.monospace = true;
	o.placeholder = '{"type":"mixed","listen":"127.0.0.1","listen_port":2080}';
	o.depends('mode', 'json');
	o.validate = function (section_id, value) {
		if (value == null || value === '') return true;
		try { JSON.parse(value); return true; }
		catch (e) { return _('Invalid JSON: ') + e.message; }
	};

	o = s.option(form.ListValue, 'protocol', _('Protocol'));
	SB_INBOUND_PROTOCOLS.forEach(function (p) { o.value(p[0], _(p[1])); });
	o.default = 'tproxy'; o.depends('mode', 'constructor');

	o = s.option(form.Value, 'listen', _('Listen address'));
	o.modalonly = true; o.placeholder = '::';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o.depends({ mode: 'constructor', protocol: 'shadowsocks' });
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o.depends({ mode: 'constructor', protocol: 'vmess' });
	o.depends({ mode: 'constructor', protocol: 'trojan' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });

	o = s.option(form.Value, 'listen_port', _('Listen port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '7893';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o.depends({ mode: 'constructor', protocol: 'shadowsocks' });
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o.depends({ mode: 'constructor', protocol: 'vmess' });
	o.depends({ mode: 'constructor', protocol: 'trojan' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });

	// tproxy
	o = s.option(widgets.DeviceSelect, 'interface', _('Interfaces (nft)'));
	o.modalonly = true; o.noaliases = true; o.multiple = true; o.placeholder = 'br-lan';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o = s.option(form.Flag, 'hijack_dns', _('Hijack DNS'));
	o.modalonly = true; o.default = '0';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o = s.option(form.Flag, 'tcp_fast_open', _('TCP Fast Open'));
	o.modalonly = true; o.default = '0';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o = s.option(form.Flag, 'udp_fragment', _('UDP fragment'));
	o.modalonly = true; o.default = '0';
	o.depends({ mode: 'constructor', protocol: 'tproxy' });

	// tproxy + tun: nft rules
	o = s.option(form.Flag, 'nft_rules', _('Create nftables rules'));
	o.modalonly = true;
	o.depends({ mode: 'constructor', protocol: 'tproxy' });
	o.depends({ mode: 'constructor', protocol: 'tun' });

	// tun
	o = s.option(form.Value, 'interface_name', _('TUN interface name'));
	o.modalonly = true; o.placeholder = 'singbox-tun';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.Value, 'inet4_address', _('IPv4 address'));
	o.modalonly = true; o.datatype = 'cidr4'; o.placeholder = '172.19.0.1/30';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.Value, 'inet6_address', _('IPv6 address'));
	o.modalonly = true; o.datatype = 'cidr6';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.Value, 'mtu', _('MTU'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '9000';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.ListValue, 'stack', _('Stack'));
	['system', 'gvisor', 'mixed'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'mixed';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.Flag, 'auto_route', _('Auto route'));
	o.modalonly = true; o.default = '1';
	o.depends({ mode: 'constructor', protocol: 'tun' });
	o = s.option(form.Flag, 'strict_route', _('Strict route'));
	o.modalonly = true; o.default = '0';
	o.depends({ mode: 'constructor', protocol: 'tun' });

	// shadowsocks
	o = s.option(form.ListValue, 'shadowsocks_method', _('Method'));
	['aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305',
	 '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'aes-128-gcm';
	o.depends({ mode: 'constructor', protocol: 'shadowsocks' });

	// users (vless/vmess/trojan/hysteria2)
	o = s.option(form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o.depends({ mode: 'constructor', protocol: 'vmess' });
	o = s.option(form.Value, 'server_password', _('Password'));
	o.modalonly = true; o.password = true;
	o.depends({ mode: 'constructor', protocol: 'shadowsocks' });
	o.depends({ mode: 'constructor', protocol: 'trojan' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.ListValue, 'vless_flow', _('Flow'));
	o.value('none', _('None')); o.value('xtls-rprx-vision', 'xtls-rprx-vision');
	o.modalonly = true; o.default = 'none';
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o = s.option(form.Value, 'vmess_alter_id', _('Alter ID'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '0';
	o.depends({ mode: 'constructor', protocol: 'vmess' });

	// hysteria2 specifics
	o = s.option(form.ListValue, 'hysteria2_obfs_type', _('Obfuscation'));
	o.value('none', _('None')); o.value('salamander', 'salamander');
	o.modalonly = true; o.default = 'none';
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'hysteria2_obfs_password', _('Obfs password'));
	o.modalonly = true; o.password = true;
	o.depends({ mode: 'constructor', protocol: 'hysteria2', hysteria2_obfs_type: 'salamander' });
	o = s.option(form.Value, 'up_mbps', _('Up Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'down_mbps', _('Down Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });

	// TLS (vless/vmess/trojan/hysteria2)
	o = s.option(form.ListValue, 'security', _('Security'));
	o.value('none', _('None')); o.value('tls', 'TLS'); o.value('reality', 'Reality');
	o.modalonly = true; o.default = 'none';
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o.depends({ mode: 'constructor', protocol: 'vmess' });
	o.depends({ mode: 'constructor', protocol: 'trojan' });
	o = s.option(form.Value, 'tls_server_name', _('TLS server name'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vless', security: 'reality' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'tls_certificate_path', _('Certificate path'));
	o.modalonly = true; o.placeholder = '/etc/ssl/cert.pem';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'tls_key_path', _('Key path'));
	o.modalonly = true; o.placeholder = '/etc/ssl/key.pem';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'tls_alpn', _('ALPN (comma-separated)'));
	o.modalonly = true; o.placeholder = 'h2,http/1.1';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ mode: 'constructor', protocol: 'hysteria2' });

	// Reality specifics (vless)
	o = s.option(form.Value, 'reality_private_key', _('Reality private key'));
	o.modalonly = true; o.password = true;
	o.depends({ protocol: 'vless', security: 'reality' });
	o = s.option(form.Value, 'reality_short_id', _('Reality short ID'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'reality' });
	o = s.option(form.Value, 'reality_handshake_server', _('Handshake server'));
	o.modalonly = true; o.placeholder = 'www.example.com';
	o.depends({ protocol: 'vless', security: 'reality' });
	o = s.option(form.Value, 'reality_handshake_server_port', _('Handshake server port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '443';
	o.depends({ protocol: 'vless', security: 'reality' });

	// transport (vless/vmess/trojan)
	o = s.option(form.ListValue, 'transport', _('Transport'));
	['none', 'ws', 'grpc', 'httpupgrade'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'none';
	o.depends({ mode: 'constructor', protocol: 'vless' });
	o.depends({ mode: 'constructor', protocol: 'vmess' });
	o.depends({ mode: 'constructor', protocol: 'trojan' });
	o = s.option(form.Value, 'transport_path', _('Transport path'));
	o.modalonly = true; o.placeholder = '/';
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_host', _('Transport host'));
	o.modalonly = true;
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_service_name', _('gRPC service name'));
	o.modalonly = true;
	o.depends({ transport: 'grpc' });

	// advanced merge
	o = s.option(form.TextValue, 'extra_json', _('Advanced JSON (merged)'));
	o.modalonly = true; o.rows = 4; o.monospace = true;
	o.placeholder = '{"sniff":true}';
	o.depends('mode', 'constructor');
	o.validate = function (section_id, value) {
		if (value == null || value === '') return true;
		try { JSON.parse(value); return true; }
		catch (e) { return _('Invalid JSON: ') + e.message; }
	};

	return m;
}

function buildOutboundsMap() {
	var m = new form.Map('singbox-ui', _('Outbounds'),
		_('Define outbounds: direct, block, or proxy via interface / URL / raw JSON / subscription.'));

	var s = m.section(form.GridSection, 'outbound', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'proxy_type') || '';
		return _('Outbound') + ': ' + section_id + (t ? ' (' + _(t) + ')' : '');
	};
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.ListValue, 'proxy_type', _('Type'));
	o.value('interface',    _('Interface'));
	o.value('constructor',  _('Constructor'));
	o.value('url',          _('URL (share link)'));
	o.value('json',         _('Raw JSON'));
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	o = s.option(form.ListValue, 'protocol', _('Protocol'));
	[['vless','VLESS'],['vmess','VMess'],['trojan','Trojan'],
	 ['hysteria2','Hysteria2'],['shadowsocks','Shadowsocks']].forEach(function (p) { o.value(p[0], p[1]); });
	o.modalonly = true; o.default = 'vless';
	o.depends('proxy_type', 'constructor');

	o = s.option(form.Value, 'server', _('Server'));
	o.modalonly = true; o.placeholder = 'example.com';
	o.depends('proxy_type', 'constructor');
	o = s.option(form.Value, 'server_port', _('Server port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '443';
	o.depends('proxy_type', 'constructor');

	o = s.option(form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends({ proxy_type: 'constructor', protocol: 'vless' });
	o.depends({ proxy_type: 'constructor', protocol: 'vmess' });
	o = s.option(form.Value, 'server_password', _('Password'));
	o.modalonly = true; o.password = true;
	o.depends({ proxy_type: 'constructor', protocol: 'trojan' });
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o.depends({ proxy_type: 'constructor', protocol: 'shadowsocks' });

	o = s.option(form.ListValue, 'vless_flow', _('Flow'));
	o.value('none', _('None')); o.value('xtls-rprx-vision', 'xtls-rprx-vision');
	o.modalonly = true; o.default = 'none';
	o.depends({ proxy_type: 'constructor', protocol: 'vless' });
	o = s.option(form.Value, 'vmess_alter_id', _('Alter ID'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '0';
	o.depends({ proxy_type: 'constructor', protocol: 'vmess' });
	o = s.option(form.ListValue, 'vmess_security', _('Cipher'));
	['auto','none','aes-128-gcm','chacha20-poly1305'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'auto';
	o.depends({ proxy_type: 'constructor', protocol: 'vmess' });
	o = s.option(form.ListValue, 'shadowsocks_method', _('Method'));
	['aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305',
	 '2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'aes-128-gcm';
	o.depends({ proxy_type: 'constructor', protocol: 'shadowsocks' });

	o = s.option(form.ListValue, 'hysteria2_obfs_type', _('Obfuscation'));
	o.value('none', _('None')); o.value('salamander', 'salamander');
	o.modalonly = true; o.default = 'none';
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'hysteria2_obfs_password', _('Obfs password'));
	o.modalonly = true; o.password = true;
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2', hysteria2_obfs_type: 'salamander' });
	o = s.option(form.Value, 'up_mbps', _('Up Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'down_mbps', _('Down Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });

	// TLS (vless/vmess/trojan; hysteria2 is always TLS)
	o = s.option(form.ListValue, 'security', _('Security'));
	o.value('none', _('None')); o.value('tls', 'TLS'); o.value('reality', 'Reality');
	o.modalonly = true; o.default = 'none';
	o.depends({ proxy_type: 'constructor', protocol: 'vless' });
	o.depends({ proxy_type: 'constructor', protocol: 'vmess' });
	o.depends({ proxy_type: 'constructor', protocol: 'trojan' });
	o = s.option(form.Value, 'tls_server_name', _('TLS server name'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vless', security: 'reality' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Flag, 'tls_insecure', _('Allow insecure'));
	o.modalonly = true; o.default = '0';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vless', security: 'reality' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.Value, 'tls_alpn', _('ALPN (comma-separated)'));
	o.modalonly = true; o.placeholder = 'h2,http/1.1';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends({ proxy_type: 'constructor', protocol: 'hysteria2' });
	o = s.option(form.ListValue, 'utls_fingerprint', _('uTLS fingerprint'));
	['','chrome','firefox','safari','edge','random'].forEach(function (v) { o.value(v, v || _('None')); });
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vless', security: 'reality' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o = s.option(form.Value, 'reality_public_key', _('Reality public key'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'reality' });
	o = s.option(form.Value, 'reality_short_id', _('Reality short ID'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'reality' });

	// transport (vless/vmess/trojan)
	o = s.option(form.ListValue, 'transport', _('Transport'));
	['none','ws','grpc','httpupgrade'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'none';
	o.depends({ proxy_type: 'constructor', protocol: 'vless' });
	o.depends({ proxy_type: 'constructor', protocol: 'vmess' });
	o.depends({ proxy_type: 'constructor', protocol: 'trojan' });
	o = s.option(form.Value, 'transport_path', _('Transport path'));
	o.modalonly = true; o.placeholder = '/';
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_host', _('Transport host'));
	o.modalonly = true;
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_service_name', _('gRPC service name'));
	o.modalonly = true;
	o.depends({ transport: 'grpc' });

	o = s.option(form.TextValue, 'extra_json', _('Advanced JSON (merged)'));
	o.modalonly = true; o.rows = 4; o.monospace = true; o.placeholder = '{"multiplex":{"enabled":true}}';
	o.depends('proxy_type', 'constructor');
	o.validate = function (section_id, value) {
		if (value == null || value === '') return true;
		try { JSON.parse(value); return true; } catch (e) { return _('Invalid JSON: ') + e.message; }
	};

	o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
	o.modalonly = true;
	o.noaliases = true;
	o.depends('proxy_type', 'interface');

	o = s.option(form.Value, 'proxy_url', _('URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
	o.depends('proxy_type', 'url');

	o = s.option(form.TextValue, 'proxy_json', _('JSON outbound'));
	o.modalonly   = true;
	o.rows        = 5;
	o.monospace   = true;
	o.placeholder = '{"type":"vless","server":"host","server_port":443,"uuid":"..."}';
	o.depends('proxy_type', 'json');
	o.validate    = function (section_id, value) {
		if (value == null || value === '') return true;
		try { JSON.parse(value); return true; }
		catch (e) { return _('Invalid JSON: ') + e.message; }
	};

	o = s.option(form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.ListValue, 'sub_update_via', _('Update via'));
	o.modalonly = true;
	o.depends('proxy_type', 'subscription');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		this.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec.proxy_type === 'interface')
				this.value(sec['.name'], sec['.name'] + ' (' + (sec.interface || '?') + ')');
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};

	o = s.option(form.Value, 'sub_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '3600';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.Flag, 'sub_multi', _('Expand to selector'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.ListValue, 'sub_selector_type', _('Selector type'));
	o.modalonly = true;
	o.value('selector', 'selector');
	o.value('urltest',  'urltest');
	o.default = 'selector';
	o.depends({ proxy_type: 'subscription', sub_multi: '1' });

	o = s.option(form.Value, 'sub_urltest_url', _('URL-test URL'));
	o.modalonly   = true;
	o.placeholder = 'https://www.gstatic.com/generate_204';
	o.depends({ proxy_type: 'subscription', sub_multi: '1', sub_selector_type: 'urltest' });

	return m;
}

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
	o = s.option(form.Value, 'detour', _('Detour (outbound or direct)')); o.modalonly = true; o.placeholder = 'direct';
	o.depends('type','udp'); o.depends('type','tls'); o.depends('type','https');
	o = s.option(form.Value, 'domain_resolver', _('Domain resolver (dns_server tag)')); o.modalonly = true;
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

	// -- Settings --
	s = m.section(form.NamedSection, 'dns', 'dns', _('DNS Settings'));
	s.anonymous = true;
	o = s.option(form.ListValue, 'final', _('Final server')); loadDnsServerList(o, true);
	o = s.option(form.ListValue, 'strategy', _('Strategy'));
	[['','default'],['prefer_ipv4','prefer_ipv4'],['prefer_ipv6','prefer_ipv6'],
	 ['ipv4_only','ipv4_only'],['ipv6_only','ipv6_only']].forEach(function (p) {
		o.value(p[0], p[1] === 'default' ? _('Default') : p[1]);
	});
	o = s.option(form.Flag, 'independent_cache', _('Independent cache')); o.default = '0';

	return m;
}

function buildGeneralMap() {
	var m = new form.Map('singbox-ui', _('General'),
		_('Global sing-box settings: cache file, log.'));

	var s, o;

	// -- Cache --
	s = m.section(form.NamedSection, 'cache', 'cache', _('Cache file'));
	s.anonymous = true;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.rmempty = false;
	o = s.option(form.Flag, 'store_fakeip', _('Store FakeIP mappings'));
	o.depends('enabled', '1');
	o = s.option(form.Value, 'path', _('Path'));
	o.placeholder = '/tmp/singbox-ui-cache.db';
	o.depends('enabled', '1');

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

function wireTabs(root, headerSelector, paneByTab, defaultTab) {
	var headerLis = root.querySelectorAll(headerSelector + ' > li');
	function activate(tab) {
		headerLis.forEach(function (el) {
			el.classList.remove('cbi-tab', 'cbi-tab-disabled');
			el.classList.add(el.getAttribute('data-tab') === tab ? 'cbi-tab' : 'cbi-tab-disabled');
		});
		Object.keys(paneByTab).forEach(function (k) {
			paneByTab[k].style.display = (k === tab) ? '' : 'none';
		});
	}
	headerLis.forEach(function (el) {
		el.addEventListener('click', function () { activate(el.getAttribute('data-tab')); });
	});
	activate(defaultTab);
}

function notify(promise, okLabel, errPrefix) {
	return promise.then(function (res) {
		if (res && res.status === 'ok') {
			ui.addNotification(null, E('p', _(okLabel)), 'info');
		} else {
			var msg = (res && res.message) || _('unknown error');
			ui.addNotification(null, E('p', errPrefix + ': ' + msg), 'danger');
		}
		return res;
	}, function (err) {
		ui.addNotification(null, E('p', errPrefix + ': ' + (err.message || err)), 'danger');
	});
}

function renderActionBar(statusHolder) {
	function refreshStatus() { renderStatusPanel(statusHolder); }
	function btn(label, handler) {
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function () {
				return Promise.resolve(handler.call(this)).then(refreshStatus);
			})
		}, _(label));
	}
	return E('div', { 'class': 'sb-actionbar', 'style': 'display:flex;gap:.5em;margin:.5em 0' }, [
		btn(_('Refresh subscriptions'), function () {
			return notify(callRefresh('subscriptions'), 'Done', _('Refresh subscriptions failed'));
		}),
		btn(_('Refresh rule-sets'), function () {
			return notify(callRefresh('rulesets'),      'Done', _('Refresh rule-sets failed'));
		}),
		btn(_('Restart service'), function () {
			return notify(callRestart(),                'Done', _('Restart failed'));
		}),
		btn(_('Preview generated config'), function () {
			return callReadConfig().then(function (res) {
				if (!res || res.status !== 'ok') {
					ui.addNotification(null, E('p', (res && res.message) || _('not generated')), 'danger');
					return;
				}
				ui.showModal(_('Preview generated config'), [
					E('pre', { 'style': 'max-height:60vh;overflow:auto;font-family:monospace' }, res.content),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
					])
				]);
			});
		})
	]);
}

function renderStatusPanel(holder) {
	// Use the server-supplied `now` so 'X ago' stays accurate even when the
	// browser clock has drifted from the router (common on routers without NTP).
	function fmtAgo(now, mt) {
		if (!mt) return _('never');
		var ago = Math.max(0, now - mt);
		if (ago < 60)    return ago + 's';
		if (ago < 3600)  return Math.floor(ago / 60)   + 'm';
		if (ago < 86400) return Math.floor(ago / 3600) + 'h';
		return Math.floor(ago / 86400) + 'd';
	}

	return callStatus().then(function (res) {
		holder.innerHTML = '';
		if (!res || res.status !== 'ok') {
			holder.appendChild(E('em', _('Status unavailable')));
			return;
		}
		var rows = [];
		rows.push(E('div', {}, [
			E('strong', _('Status') + ': '),
			E('span', { 'style': 'color:' + (res.running ? '#2e7d32' : '#c62828') },
			  res.running ? _('Service running') : _('Service stopped'))
		]));
		function entryList(label, items) {
			if (!items || !items.length) return null;
			return E('div', {}, [
				E('strong', label + ': '),
				items.map(function (it) {
					return it.name + ' (' + fmtAgo(res.now, it.mtime) + ')';
				}).join(', ')
			]);
		}
		var sub = entryList(_('Subscriptions'), res.subscriptions);
		if (sub) rows.push(sub);
		var rs = entryList(_('Rule-Sets'), res.rulesets);
		if (rs) rows.push(rs);

		rows.forEach(function (r) { holder.appendChild(r); });
	});
}

return view.extend({
	load: function () { return uci.load('singbox-ui'); },

	render: function () {
		var self = this;
		var mInbounds     = buildInboundsMap();
		var mOutbounds    = buildOutboundsMap();
		var mRulesets     = buildRulesetsMap();
		var mRouteRules   = buildRouteRulesMap();
		var mRouteDefault = buildRouteDefaultMap();
		var mDns          = buildDnsMap();
		var mGeneral      = buildGeneralMap();

		self._maps = [ mInbounds, mOutbounds, mRulesets, mRouteRules, mRouteDefault, mDns, mGeneral ];

		return Promise.all(self._maps.map(function (m) { return m.render(); }))
		.then(function (nodes) {
			var inboundsNode   = nodes[0];
			var outboundsNode  = nodes[1];
			var rulesetsNode   = nodes[2];
			var routerulesNode = nodes[3];
			var routedefNode   = nodes[4];
			var dnsNode        = nodes[5];
			var generalNode    = nodes[6];

			var statusHolder = E('div', { 'class': 'sb-status', 'style': 'margin:.5em 0;padding:.5em;border:1px solid #ddd;border-radius:4px' });
			var actionBar    = renderActionBar(statusHolder);

			var outputWrap = E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-subtab-header' }, [
					E('li', { 'data-tab': 'outbounds'  }, _('Outbounds')),
					E('li', { 'data-tab': 'rulesets'   }, _('Rule-Sets')),
					E('li', { 'data-tab': 'routerules' }, _('Route Rules')),
					E('li', { 'data-tab': 'routedef'   }, _('Default'))
				]),
				outboundsNode,
				rulesetsNode,
				routerulesNode,
				routedefNode
			]);

			var root = E('div', {}, [
				actionBar,
				statusHolder,
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', { 'data-tab': 'inbounds' }, _('Inbounds')),
					E('li', { 'data-tab': 'output'  }, _('Output')),
					E('li', { 'data-tab': 'dns'     }, _('DNS')),
					E('li', { 'data-tab': 'general' }, _('General'))
				]),
				inboundsNode,
				outputWrap,
				dnsNode,
				generalNode
			]);

			setTimeout(function () {
				wireTabs(root, '.sb-subtab-header', {
					outbounds:  outboundsNode,
					rulesets:   rulesetsNode,
					routerules: routerulesNode,
					routedef:   routedefNode
				}, 'outbounds');
				wireTabs(root, '.sb-tab-header', {
					inbounds: inboundsNode,
					output:   outputWrap,
					dns:      dnsNode,
					general:  generalNode
				}, 'inbounds');
				renderStatusPanel(statusHolder);
			}, 0);

			return root;
		});
	},

	handleSave: function (ev) {
		// All maps share one uci.state, so calling m.save() on each in parallel
		// fires duplicate RPC delete/set/add calls — the second copy of any
		// delete fails with "ubus code 4: Resource not found" because the
		// first copy already removed the target. Parse all maps to stage
		// changes locally, then flush once via uci.save().
		return Promise.all(this._maps.map(function (m) {
			return m.parse();
		})).then(function () { return uci.save(); });
	},

	handleSaveApply: function (ev, mode) {
		return this.handleSave(ev, true).then(function () {
			return ui.changes.apply(mode === 'force-apply');
		});
	},

	handleReset: null
});
