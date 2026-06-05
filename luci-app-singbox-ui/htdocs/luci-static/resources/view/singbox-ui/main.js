'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.common as SbCommon';
'require tools.widgets as widgets';

var callRefresh    = SbRpc.callRefresh;
var callRestart    = SbRpc.callRestart;
var callStatus     = SbRpc.callStatus;
var callReadConfig = SbRpc.callReadConfig;
var callClash      = SbRpc.callClash;
var callDhcpLeases = SbRpc.callDhcpLeases;

var loadOutboundList = SbCommon.loadOutboundList;
var addRenameField   = SbCommon.addRenameField;
var wireTabs         = SbCommon.wireTabs;
var notify           = SbCommon.notify;

// Constrained to the protocols inbound.uc actually builds — importing
// anything else would create a UCI section that generate.uc silently drops.
var SB_INBOUND_KNOWN = {
	'tproxy': true, 'tun': true, 'direct': true,
	'shadowsocks': true, 'vless': true, 'vmess': true, 'trojan': true,
	'hysteria2': true,
};

function __sb_jsonImportInbound(o) {
	var out = { ok: false, errors: [], fields: {} };
	if (!o || typeof o !== 'object' || Array.isArray(o)) {
		out.errors.push(_('Not a JSON object'));
		return out;
	}
	if (!o.type) { out.errors.push(_('Missing "type" field')); return out; }
	if (!SB_INBOUND_KNOWN[o.type]) {
		out.errors.push(_('Unknown inbound type: ') + o.type);
		return out;
	}
	if (o.server && o.server_port && !o.listen) {
		out.errors.push(_('Looks like an outbound (has "server" without "listen"). Use the outbound importer.'));
		return out;
	}
	var f = out.fields;
	f.protocol = o.type;
	if (o.listen      != null) f.listen      = String(o.listen);
	if (o.listen_port != null) f.listen_port = +o.listen_port;
	if (o.network     != null) f.network     = String(o.network);

	if (o.type === 'shadowsocks') {
		if (o.method)   f.shadowsocks_method = o.method;
		if (o.password) f.server_password    = o.password;
	}
	if (o.type === 'vless' || o.type === 'vmess'
	    || o.type === 'trojan' || o.type === 'hysteria2') {
		var u = (o.users && o.users[0]) || {};
		if (u.uuid)     f.server_uuid     = u.uuid;
		if (u.password) f.server_password = u.password;
		if (u.flow)     f.vless_flow      = u.flow;
		// sing-box uses snake_case `alter_id`; accept legacy camelCase too
		// in case the user pasted a v2ray-ng-style config.
		var aid = (u.alter_id != null) ? u.alter_id : u.alterId;
		if (aid != null) f.vmess_alter_id = String(aid);
	}
	if (o.type === 'tun') {
		if (o.interface_name) f.interface_name = o.interface_name;
		if (o.mtu) f.mtu = String(o.mtu);
		if (o.stack) f.stack = o.stack;
		if (Array.isArray(o.address)) {
			for (var i = 0; i < o.address.length; i++) {
				var a = o.address[i];
				if (a.indexOf(':') < 0) f.inet4_address = a;
				else f.inet6_address = a;
			}
		}
		if (o.auto_route)   f.auto_route   = '1';
		if (o.strict_route) f.strict_route = '1';
	}
	if (o.tls) {
		f.security = (o.tls.reality && o.tls.reality.enabled) ? 'reality' : 'tls';
		if (o.tls.server_name)      f.tls_server_name      = o.tls.server_name;
		if (o.tls.certificate_path) f.tls_certificate_path = o.tls.certificate_path;
		if (o.tls.key_path)         f.tls_key_path         = o.tls.key_path;
		if (Array.isArray(o.tls.alpn)) f.tls_alpn = o.tls.alpn;
		if (o.tls.reality) {
			if (o.tls.reality.private_key) f.reality_private_key = o.tls.reality.private_key;
			if (Array.isArray(o.tls.reality.short_id))
				f.reality_short_id = o.tls.reality.short_id[0];
			if (o.tls.reality.handshake) {
				if (o.tls.reality.handshake.server)
					f.reality_handshake_server      = o.tls.reality.handshake.server;
				if (o.tls.reality.handshake.server_port)
					f.reality_handshake_server_port = String(o.tls.reality.handshake.server_port);
			}
		}
	}
	if (o.transport && o.transport.type) {
		f.transport = o.transport.type;
		if (o.transport.path)         f.transport_path         = o.transport.path;
		if (o.transport.service_name) f.transport_service_name = o.transport.service_name;
		if (o.transport.headers && o.transport.headers.Host)
			f.transport_host = o.transport.headers.Host;
		if (o.transport.host != null) {
			// `http` transport carries an array of vhosts; ws/httpupgrade
			// stays a single scalar. Route each into its own UCI field.
			if (o.transport.type === 'http')
				f.transport_hosts = Array.isArray(o.transport.host)
					? o.transport.host : [ o.transport.host ];
			else
				f.transport_host = Array.isArray(o.transport.host)
					? o.transport.host[0] : o.transport.host;
		}
		if (o.transport.type === 'xhttp' && o.transport.mode)
			f.transport_xhttp_mode = o.transport.mode;
	}
	if (o.type === 'hysteria2') {
		if (o.obfs && o.obfs.type) {
			f.hysteria2_obfs_type     = o.obfs.type;
			f.hysteria2_obfs_password = o.obfs.password || '';
		}
		if (o.up_mbps   != null) f.up_mbps   = String(o.up_mbps);
		if (o.down_mbps != null) f.down_mbps = String(o.down_mbps);
	}
	out.ok = true;
	return out;
}

// Expose as a window-level global so the Node test harness can pick it up
// after the LuCI fragment is evaluated. LuCI itself doesn't need this.
window.__sb_jsonImportInbound = __sb_jsonImportInbound;

// Constrained to the proxy protocols outbound.uc build_constructor_for()
// actually emits. `direct`/`interface`/`url`/`subscription` are UI-only
// shapes managed via dedicated fields, not by the JSON importer.
var SB_OUTBOUND_KNOWN = {
	'vless': true, 'vmess': true, 'trojan': true, 'hysteria2': true,
	'shadowsocks': true,
};

function __sb_jsonImportOutbound(o) {
	var out = { ok: false, errors: [], fields: {} };
	if (!o || typeof o !== 'object' || Array.isArray(o)) {
		out.errors.push(_('Not a JSON object'));
		return out;
	}
	if (!o.type) { out.errors.push(_('Missing "type" field')); return out; }
	if (!SB_OUTBOUND_KNOWN[o.type]) {
		out.errors.push(_('Unknown outbound type: ') + o.type);
		return out;
	}
	if (o.listen != null) {
		out.errors.push(_('Looks like an inbound (has "listen"). Use the inbound importer.'));
		return out;
	}
	var f = out.fields;
	f.type = o.type;
	if (o.server)      f.server      = o.server;
	if (o.server_port) f.server_port = +o.server_port;

	if (o.type === 'shadowsocks') {
		if (o.method)   f.shadowsocks_method = o.method;
		if (o.password) f.server_password    = o.password;
	}
	if (o.type === 'vless' || o.type === 'vmess') {
		if (o.uuid) f.server_uuid = o.uuid;
		if (o.flow) f.vless_flow  = o.flow;
		if (o.alter_id != null) f.vmess_alter_id = String(o.alter_id);
		if (o.security)         f.vmess_security = o.security;
	}
	if (o.type === 'trojan' || o.type === 'hysteria2') {
		if (o.password) f.server_password = o.password;
	}
	if (o.type === 'hysteria2') {
		if (o.up_mbps   != null) f.up_mbps   = String(o.up_mbps);
		if (o.down_mbps != null) f.down_mbps = String(o.down_mbps);
		if (o.obfs && o.obfs.type) {
			f.hysteria2_obfs_type     = o.obfs.type;
			f.hysteria2_obfs_password = o.obfs.password || '';
		}
	}
	if (o.tls) {
		f.security = (o.tls.reality && o.tls.reality.enabled) ? 'reality' : 'tls';
		if (o.tls.server_name) f.tls_server_name = o.tls.server_name;
		if (o.tls.insecure)    f.tls_insecure    = '1';
		if (Array.isArray(o.tls.alpn)) f.tls_alpn = o.tls.alpn;
		if (o.tls.utls && o.tls.utls.fingerprint) f.utls_fingerprint = o.tls.utls.fingerprint;
		if (o.tls.reality) {
			if (o.tls.reality.public_key) f.reality_public_key = o.tls.reality.public_key;
			if (o.tls.reality.short_id)   f.reality_short_id   = o.tls.reality.short_id;
		}
	}
	if (o.transport && o.transport.type) {
		f.transport = o.transport.type;
		if (o.transport.path)         f.transport_path         = o.transport.path;
		if (o.transport.service_name) f.transport_service_name = o.transport.service_name;
		if (o.transport.headers && o.transport.headers.Host)
			f.transport_host = o.transport.headers.Host;
		if (o.transport.host != null) {
			if (o.transport.type === 'http')
				f.transport_hosts = Array.isArray(o.transport.host)
					? o.transport.host : [ o.transport.host ];
			else
				f.transport_host = Array.isArray(o.transport.host)
					? o.transport.host[0] : o.transport.host;
		}
		if (o.transport.type === 'xhttp' && o.transport.mode)
			f.transport_xhttp_mode = o.transport.mode;
	}
	out.ok = true;
	return out;
}

window.__sb_jsonImportOutbound = __sb_jsonImportOutbound;

var SB_INBOUND_PROTOCOLS = [
	['direct',      'Direct (DNS / port-forward)'],
	['tproxy',      'TProxy (transparent)'],
	['tun',         'TUN'],
	['shadowsocks', 'Shadowsocks'],
	['vless',       'VLESS'],
	['vmess',       'VMess'],
	['trojan',      'Trojan'],
	['hysteria2',   'Hysteria2']
];

function openJsonImportModal(kind, m) {
	var ta = E('textarea', {
		'rows': 12,
		'class': 'cbi-input-textarea',
		'style': 'width:100%;font-family:monospace;',
		'placeholder': kind === 'inbound'
			? '{"type":"shadowsocks","listen":"::","listen_port":8388,"method":"aes-256-gcm","password":"p"}'
			: '{"type":"vless","server":"a.b","server_port":443,"uuid":"…"}'
	});
	var err = E('div', { 'style': 'color:#c33;margin-top:8px;' });

	function onImport() {
		err.textContent = '';
		var parsed;
		try { parsed = JSON.parse(ta.value); }
		catch (e) { err.textContent = _('Invalid JSON: ') + e.message; return; }

		var res = (kind === 'inbound')
			? __sb_jsonImportInbound(parsed)
			: __sb_jsonImportOutbound(parsed);
		if (!res.ok) { err.textContent = res.errors.join('; '); return; }

		// Distinguish inbound vs outbound by suffix so user-facing names stay
		// scannable (vless_in vs vless_out instead of two `vless_in`s).
		var suffix = (kind === 'outbound') ? '_out' : '_in';
		var base = (res.fields.protocol || res.fields.type || 'import') + suffix;
		var sid = base, i = 1;
		while (uci.get('singbox-ui', sid)) { sid = base + '_' + (i++); }
		uci.add('singbox-ui', kind, sid);
		uci.set('singbox-ui', sid, 'enabled', '1');
		Object.keys(res.fields).forEach(function (k) {
			var v = res.fields[k];
			// LuCI uci.set accepts arrays for list options; importer keeps
			// arrays (tls_alpn, transport_hosts) intact so the form renders
			// them as multi-value lists instead of one comma-joined scalar.
			if (Array.isArray(v))
				uci.set('singbox-ui', sid, k, v.map(String));
			else
				uci.set('singbox-ui', sid, k, String(v));
		});
		ui.hideModal();
		// Re-render the page so the newly-added section shows in the grid.
		// Map.parse/render is non-trivial to splice in mid-lifecycle —
		// uci.save() inside the page wrapper would also clobber other
		// pending edits — so we save what we just imported and reload.
		uci.save().then(function () { window.location.reload(); });
	}

	ui.showModal(_('Import JSON'), [
		E('p', {}, _('Paste a sing-box ') + kind + _(' object. Fields will be parsed and a new section created.')),
		ta, err,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-positive', 'click': onImport }, _('Import'))
		])
	]);
}

function buildInboundsMap() {
	var m = new form.Map('singbox-ui', _('Inbounds'),
		_('Define inbounds: protocol-first constructor. ' +
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

	var origRenderSectionAdd = s.renderSectionAdd;
	s.renderSectionAdd = function () {
		var node = origRenderSectionAdd.apply(this, arguments);
		var btn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:8px;',
			'click': ui.createHandlerFn(this, function () {
				openJsonImportModal('inbound', m);
				return false;
			})
		}, _('Import JSON'));
		if (node && node.appendChild) node.appendChild(btn);
		return node;
	};

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default = '1'; o.editable = true;

	o = s.option(form.ListValue, 'protocol', _('Protocol'));
	SB_INBOUND_PROTOCOLS.forEach(function (p) { o.value(p[0], _(p[1])); });
	o.default = 'tproxy'; o.rmempty = false;

	o = s.option(form.Value, 'listen', _('Listen address'));
	o.modalonly = true; o.placeholder = '::';
	o.depends('protocol', 'direct');
	o.depends('protocol', 'tproxy');
	o.depends('protocol', 'shadowsocks');
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'trojan');
	o.depends('protocol', 'hysteria2');

	o = s.option(form.Value, 'listen_port', _('Listen port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '7893';
	o.depends('protocol', 'direct');
	o.depends('protocol', 'tproxy');
	o.depends('protocol', 'shadowsocks');
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'trojan');
	o.depends('protocol', 'hysteria2');

	// direct
	o = s.option(form.ListValue, 'network', _('Network'));
	o.modalonly = true;
	o.value('', _('Both (tcp+udp)'));
	o.value('tcp', 'tcp');
	o.value('udp', 'udp');
	o.depends('protocol', 'direct');

	o = s.option(form.Flag, 'dns_listener', _('Hijack DNS'));
	o.modalonly = true;
	o.default = '1';
	o.depends('protocol', 'direct');
	o.description = _('Auto-emits a hijack-dns route rule for this inbound.');

	// tproxy
	o = s.option(widgets.DeviceSelect, 'interface', _('Interfaces (nft)'));
	o.modalonly = true; o.noaliases = true; o.multiple = true; o.placeholder = 'br-lan';
	o.depends('protocol', 'tproxy');
	o = s.option(form.Flag, 'hijack_dns', _('Hijack DNS'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');
	o = s.option(form.Flag, 'tcp_fast_open', _('TCP Fast Open'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');
	o = s.option(form.Flag, 'udp_fragment', _('UDP fragment'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');

	// tproxy + tun: nft rules
	o = s.option(form.Flag, 'nft_rules', _('Create nftables rules'));
	o.modalonly = true;
	o.depends('protocol', 'tproxy');
	o.depends('protocol', 'tun');

	// tun
	o = s.option(form.Value, 'interface_name', _('TUN interface name'));
	o.modalonly = true; o.placeholder = 'singbox-tun';
	o.depends('protocol', 'tun');
	o = s.option(form.Value, 'inet4_address', _('IPv4 address'));
	o.modalonly = true; o.datatype = 'cidr4'; o.placeholder = '172.19.0.1/30';
	o.depends('protocol', 'tun');
	o = s.option(form.Value, 'inet6_address', _('IPv6 address'));
	o.modalonly = true; o.datatype = 'cidr6';
	o.depends('protocol', 'tun');
	o = s.option(form.Value, 'mtu', _('MTU'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '9000';
	o.depends('protocol', 'tun');
	o = s.option(form.ListValue, 'stack', _('Stack'));
	['system', 'gvisor', 'mixed'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'mixed';
	o.depends('protocol', 'tun');
	o = s.option(form.Flag, 'auto_route', _('Auto route'));
	o.modalonly = true; o.default = '1';
	o.depends('protocol', 'tun');
	o = s.option(form.Flag, 'strict_route', _('Strict route'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tun');

	// shadowsocks
	o = s.option(form.ListValue, 'shadowsocks_method', _('Method'));
	['aes-128-gcm', 'aes-256-gcm', 'chacha20-ietf-poly1305',
	 '2022-blake3-aes-128-gcm', '2022-blake3-aes-256-gcm'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'aes-128-gcm';
	o.depends('protocol', 'shadowsocks');

	// users (vless/vmess/trojan/hysteria2)
	o = s.option(form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o = s.option(form.Value, 'server_password', _('Password'));
	o.modalonly = true; o.password = true;
	o.depends('protocol', 'shadowsocks');
	o.depends('protocol', 'trojan');
	o.depends('protocol', 'hysteria2');
	o = s.option(form.ListValue, 'vless_flow', _('Flow'));
	o.value('none', _('None')); o.value('xtls-rprx-vision', 'xtls-rprx-vision');
	o.modalonly = true; o.default = 'none';
	o.depends('protocol', 'vless');
	o = s.option(form.Value, 'vmess_alter_id', _('Alter ID'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '0';
	o.depends('protocol', 'vmess');

	// hysteria2 specifics
	o = s.option(form.ListValue, 'hysteria2_obfs_type', _('Obfuscation'));
	o.value('none', _('None')); o.value('salamander', 'salamander');
	o.modalonly = true; o.default = 'none';
	o.depends('protocol', 'hysteria2');
	o = s.option(form.Value, 'hysteria2_obfs_password', _('Obfs password'));
	o.modalonly = true; o.password = true;
	o.depends({ protocol: 'hysteria2', hysteria2_obfs_type: 'salamander' });
	o = s.option(form.Value, 'up_mbps', _('Up Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('protocol', 'hysteria2');
	o = s.option(form.Value, 'down_mbps', _('Down Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('protocol', 'hysteria2');

	// TLS (vless/vmess/trojan/hysteria2)
	o = s.option(form.ListValue, 'security', _('Security'));
	o.value('none', _('None')); o.value('tls', 'TLS'); o.value('reality', 'Reality');
	o.modalonly = true; o.default = 'none';
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'trojan');
	o = s.option(form.Value, 'tls_server_name', _('TLS server name'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vless', security: 'reality' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends('protocol', 'hysteria2');
	o = s.option(form.Value, 'tls_certificate_path', _('Certificate path'));
	o.modalonly = true; o.placeholder = '/etc/ssl/cert.pem';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends('protocol', 'hysteria2');
	o = s.option(form.Value, 'tls_key_path', _('Key path'));
	o.modalonly = true; o.placeholder = '/etc/ssl/key.pem';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends('protocol', 'hysteria2');
	o = s.option(form.DynamicList, 'tls_alpn', _('ALPN'));
	o.modalonly = true; o.placeholder = 'h2';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends('protocol', 'hysteria2');

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
	['none', 'ws', 'grpc', 'httpupgrade', 'xhttp', 'http'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'none';
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'trojan');
	o = s.option(form.Value, 'transport_path', _('Transport path'));
	o.modalonly = true; o.placeholder = '/';
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o.depends({ transport: 'xhttp' }); o.depends({ transport: 'http' });
	o = s.option(form.Value, 'transport_host', _('Transport host'));
	o.modalonly = true;
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_service_name', _('gRPC service name'));
	o.modalonly = true;
	o.depends({ transport: 'grpc' });

	o = s.option(form.ListValue, 'transport_xhttp_mode', _('XHTTP mode'));
	o.modalonly = true;
	o.value('auto', 'auto');
	o.value('packet-up', 'packet-up');
	o.value('stream-up', 'stream-up');
	o.value('stream-one', 'stream-one');
	o.default = 'auto';
	o.depends({ protocol: 'vless', transport: 'xhttp' });
	o.depends({ protocol: 'vmess', transport: 'xhttp' });
	o.depends({ protocol: 'trojan', transport: 'xhttp' });

	o = s.option(form.DynamicList, 'transport_hosts', _('HTTP hosts'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', transport: 'http' });
	o.depends({ protocol: 'vmess', transport: 'http' });
	o.depends({ protocol: 'trojan', transport: 'http' });

	// Multiplex
	o = s.option(form.Flag, 'multiplex_enabled', _('Multiplex'));
	o.modalonly = true;
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'trojan');

	o = s.option(form.ListValue, 'multiplex_protocol', _('Multiplex protocol'));
	o.modalonly = true;
	['smux','yamux','h2mux'].forEach(function (v) { o.value(v, v); });
	o.default = 'smux';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_max_connections', _('Multiplex max connections'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_min_streams', _('Multiplex min streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_max_streams', _('Multiplex max streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Flag, 'multiplex_padding', _('Multiplex padding'));
	o.modalonly = true;
	o.depends('multiplex_enabled', '1');

	// Hysteria2 masquerade
	o = s.option(form.Value, 'hysteria2_masquerade', _('Masquerade URL'));
	o.modalonly = true;
	o.placeholder = 'https://www.example.com';
	o.depends('protocol', 'hysteria2');

	// vmess cipher
	o = s.option(form.ListValue, 'vmess_security', _('Cipher'));
	o.modalonly = true;
	['auto','none','aes-128-gcm','chacha20-poly1305'].forEach(function (v) { o.value(v, v); });
	o.default = 'auto';
	o.depends('protocol', 'vmess');

	// TLS extras
	o = s.option(form.Flag, 'tls_insecure', _('TLS insecure (skip verify)'));
	o.modalonly = true;
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });
	o.depends('protocol', 'hysteria2');

	o = s.option(form.Value, 'utls_fingerprint', _('uTLS fingerprint'));
	o.modalonly = true;
	o.placeholder = 'chrome';
	o.depends({ protocol: 'vless', security: 'tls' });
	o.depends({ protocol: 'vmess', security: 'tls' });
	o.depends({ protocol: 'trojan', security: 'tls' });

	return m;
}

function buildOutboundsMap() {
	var m = new form.Map('singbox-ui', _('Outbounds'),
		_('Define outbounds: direct via interface, share-link URL, subscription, or proxy constructor.'));

	var s = m.section(form.GridSection, 'outbound', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'type') || '';
		return _('Outbound') + ': ' + section_id + (t ? ' (' + _(t) + ')' : '');
	};
	addRenameField(s);

	var origRenderSectionAddOut = s.renderSectionAdd;
	s.renderSectionAdd = function () {
		var node = origRenderSectionAddOut.apply(this, arguments);
		var btn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:8px;',
			'click': ui.createHandlerFn(this, function () {
				openJsonImportModal('outbound', m);
				return false;
			})
		}, _('Import JSON'));
		if (node && node.appendChild) node.appendChild(btn);
		return node;
	};

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.ListValue, 'type', _('Type'));
	o.value('vless',        'VLESS');
	o.value('vmess',        'VMess');
	o.value('trojan',       'Trojan');
	o.value('hysteria2',    'Hysteria2');
	o.value('shadowsocks',  'Shadowsocks');
	o.value('interface',    _('Direct (interface)'));
	o.value('url',          _('Share-link URL'));
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	o = s.option(form.Value, 'server', _('Server'));
	o.modalonly = true; o.placeholder = 'example.com';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');
	o = s.option(form.Value, 'server_port', _('Server port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '443';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');

	o = s.option(form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o = s.option(form.Value, 'server_password', _('Password'));
	o.modalonly = true; o.password = true;
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');

	o = s.option(form.ListValue, 'vless_flow', _('Flow'));
	o.value('none', _('None')); o.value('xtls-rprx-vision', 'xtls-rprx-vision');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o = s.option(form.Value, 'vmess_alter_id', _('Alter ID'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '0';
	o.depends('type', 'vmess');
	o = s.option(form.ListValue, 'vmess_security', _('Cipher'));
	['auto','none','aes-128-gcm','chacha20-poly1305'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'auto';
	o.depends('type', 'vmess');
	o = s.option(form.ListValue, 'shadowsocks_method', _('Method'));
	['aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305',
	 '2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'aes-128-gcm';
	o.depends('type', 'shadowsocks');

	o = s.option(form.ListValue, 'hysteria2_obfs_type', _('Obfuscation'));
	o.value('none', _('None')); o.value('salamander', 'salamander');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'hysteria2');
	o = s.option(form.Value, 'hysteria2_obfs_password', _('Obfs password'));
	o.modalonly = true; o.password = true;
	o.depends({ type: 'hysteria2', hysteria2_obfs_type: 'salamander' });
	o = s.option(form.Value, 'up_mbps', _('Up Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('type', 'hysteria2');
	o = s.option(form.Value, 'down_mbps', _('Down Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('type', 'hysteria2');

	// TLS (vless/vmess/trojan; hysteria2 is always TLS)
	o = s.option(form.ListValue, 'security', _('Security'));
	o.value('none', _('None')); o.value('tls', 'TLS'); o.value('reality', 'Reality');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o = s.option(form.Value, 'tls_server_name', _('TLS server name'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o = s.option(form.Flag, 'tls_insecure', _('Allow insecure'));
	o.modalonly = true; o.default = '0';
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o = s.option(form.DynamicList, 'tls_alpn', _('ALPN'));
	o.modalonly = true; o.placeholder = 'h2';
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o = s.option(form.ListValue, 'utls_fingerprint', _('uTLS fingerprint'));
	['','chrome','firefox','safari','edge','random'].forEach(function (v) { o.value(v, v || _('None')); });
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o = s.option(form.Value, 'reality_public_key', _('Reality public key'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'reality' });
	o = s.option(form.Value, 'reality_short_id', _('Reality short ID'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'reality' });

	// transport (vless/vmess/trojan)
	o = s.option(form.ListValue, 'transport', _('Transport'));
	['none','ws','grpc','httpupgrade','xhttp','http'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o = s.option(form.Value, 'transport_path', _('Transport path'));
	o.modalonly = true; o.placeholder = '/';
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o.depends({ transport: 'xhttp' }); o.depends({ transport: 'http' });
	o = s.option(form.Value, 'transport_host', _('Transport host'));
	o.modalonly = true;
	o.depends({ transport: 'ws' }); o.depends({ transport: 'httpupgrade' });
	o = s.option(form.Value, 'transport_service_name', _('gRPC service name'));
	o.modalonly = true;
	o.depends({ transport: 'grpc' });

	o = s.option(form.ListValue, 'transport_xhttp_mode', _('XHTTP mode'));
	o.modalonly = true;
	o.value('auto', 'auto'); o.value('packet-up', 'packet-up');
	o.value('stream-up', 'stream-up'); o.value('stream-one', 'stream-one');
	o.default = 'auto';
	o.depends({ type: 'vless', transport: 'xhttp' });
	o.depends({ type: 'vmess', transport: 'xhttp' });
	o.depends({ type: 'trojan', transport: 'xhttp' });

	o = s.option(form.DynamicList, 'transport_hosts', _('HTTP hosts'));
	o.modalonly = true;
	o.depends({ type: 'vless', transport: 'http' });
	o.depends({ type: 'vmess', transport: 'http' });
	o.depends({ type: 'trojan', transport: 'http' });

	// Multiplex
	o = s.option(form.Flag, 'multiplex_enabled', _('Multiplex'));
	o.modalonly = true;
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');

	o = s.option(form.ListValue, 'multiplex_protocol', _('Multiplex protocol'));
	o.modalonly = true;
	['smux','yamux','h2mux'].forEach(function (v) { o.value(v, v); });
	o.default = 'smux';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_max_connections', _('Multiplex max connections'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_min_streams', _('Multiplex min streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Value, 'multiplex_max_streams', _('Multiplex max streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.option(form.Flag, 'multiplex_padding', _('Multiplex padding'));
	o.modalonly = true;
	o.depends('multiplex_enabled', '1');

	// Hysteria2 masquerade
	o = s.option(form.Value, 'hysteria2_masquerade', _('Masquerade URL'));
	o.modalonly = true;
	o.placeholder = 'https://www.example.com';
	o.depends('type', 'hysteria2');

	o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
	o.modalonly = true;
	o.noaliases = true;
	o.depends('type', 'interface');
	o.description = _('For a direct-via-WAN outbound, pick the real WAN device (may differ from "wan").');

	o = s.option(form.Value, 'proxy_url', _('URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
	o.depends('type', 'url');

	o = s.option(form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('type', 'subscription');

	o = s.option(form.ListValue, 'sub_update_via', _('Update via'));
	o.modalonly = true;
	o.depends('type', 'subscription');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		this.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec.type === 'interface')
				this.value(sec['.name'], sec['.name'] + ' (' + (sec.interface || '?') + ')');
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};

	o = s.option(form.Value, 'sub_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '3600';
	o.depends('type', 'subscription');

	o = s.option(form.Flag, 'sub_multi', _('Expand to selector'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('type', 'subscription');

	o = s.option(form.ListValue, 'sub_selector_type', _('Selector type'));
	o.modalonly = true;
	o.value('selector', 'selector');
	o.value('urltest',  'urltest');
	o.default = 'selector';
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.option(form.Value, 'sub_urltest_url', _('URL-test URL'));
	o.modalonly   = true;
	o.placeholder = 'https://www.gstatic.com/generate_204';
	o.depends({ type: 'subscription', sub_multi: '1', sub_selector_type: 'urltest' });

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
	// Pinning a DNS query to a specific outbound. Dropdown of user-defined
	// outbound tags only — the auto-injected implicit `direct` is intentionally
	// not selectable because sing-box 1.12 rejects detour to a field-less
	// direct outbound at startup. Leave empty to let route rules decide.
	o = s.option(form.ListValue, 'detour', _('Detour (outbound)'));
	o.modalonly = true;
	loadOutboundList(o, true);
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

function buildMonitoring() {
	var state = {
		timer: null, prevConns: {}, closed: [], leases: {},
		filterDevice: 'all', search: '', tab: 'active',
		lastDown: null, lastUp: null
	};
	var root = E('div', { 'class': 'sb-monitoring' });

	function fmtBytes(n) {
		n = n || 0; var u = ['B','KB','MB','GB','TB']; var i = 0;
		while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
		return n.toFixed(i ? 1 : 0) + u[i];
	}
	function nameFor(ip) { return state.leases[ip] || ip; }

	function closeConn(id) {
		return callClash('DELETE', '/connections/' + id, '').then(poll);
	}
	function closeAll() {
		return callClash('DELETE', '/connections', '').then(poll);
	}

	function renderTable(conns) {
		var rows = conns.filter(function (c) {
			var src = (c.metadata && c.metadata.sourceIP) || '';
			if (state.filterDevice !== 'all' && src !== state.filterDevice) return false;
			if (state.search) {
				var hay = JSON.stringify(c).toLowerCase();
				if (hay.indexOf(state.search.toLowerCase()) < 0) return false;
			}
			return true;
		}).map(function (c) {
			var md = c.metadata || {};
			var host = md.host || md.destinationIP || '?';
			var chain = (c.chains || []).join(' / ');
			return E('tr', {}, [
				E('td', {}, host + (md.destinationPort ? ':' + md.destinationPort : '')),
				E('td', {}, nameFor(md.sourceIP || '')),
				E('td', {}, chain || md.network || ''),
				E('td', {}, fmtBytes(c.download)),
				E('td', {}, fmtBytes(c.upload)),
				E('td', {}, c.id ? E('button', {
					'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(this, function () { return closeConn(c.id); })
				}, _('Close')) : '')
			]);
		});
		return E('table', { 'class': 'table cbi-section-table' }, [
			E('tr', { 'class': 'tr table-titles' }, [
				E('th', {}, _('Host')), E('th', {}, _('Device')), E('th', {}, _('Chain')),
				E('th', {}, _('Down')), E('th', {}, _('Up')), E('th', {}, '')
			])
		].concat(rows.length ? rows : [ E('tr', {}, E('td', { 'colspan': 6 }, E('em', {}, _('No connections')))) ]));
	}

	function repaint(data) {
		var conns = (data && data.connections) || [];
		var nowIds = {}; conns.forEach(function (c) { if (c.id) nowIds[c.id] = c; });
		Object.keys(state.prevConns).forEach(function (id) {
			if (!nowIds[id]) state.closed.unshift(state.prevConns[id]);
		});
		if (state.closed.length > 100) state.closed.length = 100;
		state.prevConns = nowIds;

		var down = (data && data.downloadTotal) || 0;
		var up   = (data && data.uploadTotal)   || 0;
		var dRate = (state.lastDown == null) ? 0 : Math.max(0, down - state.lastDown);
		var uRate = (state.lastUp   == null) ? 0 : Math.max(0, up   - state.lastUp);
		state.lastDown = down; state.lastUp = up;

		var devices = {};
		conns.forEach(function (c) { var s = c.metadata && c.metadata.sourceIP; if (s) devices[s] = true; });

		root.innerHTML = '';
		root.appendChild(E('div', { 'style': 'display:flex;gap:1em;flex-wrap:wrap;align-items:center;margin:.5em 0' }, [
			E('button', { 'class': 'btn cbi-button' + (state.tab === 'active' ? ' cbi-button-action' : ''),
				'click': function () { state.tab = 'active'; repaint(data); } }, _('Active') + ' ' + conns.length),
			E('button', { 'class': 'btn cbi-button' + (state.tab === 'closed' ? ' cbi-button-action' : ''),
				'click': function () { state.tab = 'closed'; repaint(data); } }, _('Closed') + ' ' + state.closed.length),
			E('input', { 'type': 'search', 'placeholder': _('Search'), 'value': state.search,
				'keyup': function (ev) { state.search = ev.target.value; repaint(data); } }),
			(function () {
				var opts = [ E('option', { 'value': 'all' }, _('All devices')) ];
				Object.keys(devices).forEach(function (ip) {
					var attr = { 'value': ip };
					if (state.filterDevice === ip) attr.selected = '';
					opts.push(E('option', attr, nameFor(ip)));
				});
				return E('select', {
					'change': function (ev) { state.filterDevice = ev.target.value; repaint(data); }
				}, opts);
			})(),
			E('button', { 'class': 'btn cbi-button cbi-button-remove',
				'click': ui.createHandlerFn(this, function () { return closeAll(); }) }, _('Close all')),
			E('span', {}, _('↓') + ' ' + fmtBytes(dRate) + '/s  ' + _('↑') + ' ' + fmtBytes(uRate) + '/s' +
				'  (' + _('total') + ' ↓' + fmtBytes(down) + ' ↑' + fmtBytes(up) + ')')
		]));
		root.appendChild(renderTable(state.tab === 'active' ? conns : state.closed));
	}

	function poll() {
		return callClash('GET', '/connections', '').then(function (res) {
			if (!res || res.status !== 'ok') {
				root.innerHTML = '';
				root.appendChild(E('em', {}, _('Clash API unreachable — enable it in settings and restart.')));
				return;
			}
			var data;
			try { data = JSON.parse(res.body); } catch (e) { data = { connections: [] }; }
			repaint(data);
		});
	}

	function start() {
		if (state.timer) return;
		callDhcpLeases().then(function (r) {
			var arr = (r && (r.dhcp_leases || r.leases)) || [];
			(Array.isArray(arr) ? arr : []).forEach(function (l) {
				if (l.ipaddr) state.leases[l.ipaddr] = l.hostname || l.ipaddr;
			});
		}).catch(function () {});
		poll();
		state.timer = setInterval(function () {
			if (document.visibilityState === 'visible') poll();
		}, 1500);
	}
	function stop() { if (state.timer) { clearInterval(state.timer); state.timer = null; } }

	return { node: root, start: start, stop: stop };
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
		var mon           = buildMonitoring();

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
					E('li', { 'data-tab': 'inbounds'   }, _('Inbounds')),
					E('li', { 'data-tab': 'output'     }, _('Output')),
					E('li', { 'data-tab': 'dns'        }, _('DNS')),
					E('li', { 'data-tab': 'monitoring' }, _('Monitoring')),
					E('li', { 'data-tab': 'general'    }, _('General'))
				]),
				inboundsNode,
				outputWrap,
				dnsNode,
				mon.node,
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
					inbounds:   inboundsNode,
					output:     outputWrap,
					dns:        dnsNode,
					monitoring: mon.node,
					general:    generalNode
				}, 'inbounds');
				root.querySelectorAll('.sb-tab-header > li').forEach(function (el) {
					el.addEventListener('click', function () {
						if (el.getAttribute('data-tab') === 'monitoring') mon.start();
						else mon.stop();
					});
				});
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
