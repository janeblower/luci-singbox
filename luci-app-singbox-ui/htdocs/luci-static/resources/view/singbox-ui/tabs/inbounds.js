'use strict';
'require form';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.validators as SbValidators';
'require view.singbox-ui.importers.inbound as SbImpInbound';
'require view.singbox-ui.importers.outbound as SbImpOutbound';
'require view.singbox-ui.lib.rpc as SbRpc';

var loadOutboundList = SbCommon.loadOutboundList;
var addRenameField   = SbCommon.addRenameField;

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
			? SbImpInbound.jsonImportInbound(parsed)
			: SbImpOutbound.jsonImportOutbound(parsed);
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
		// Phase C1: stage the imported section into uci.state only. Do NOT
		// uci.save() and do NOT reload the page — that previously raced with
		// main.js's handleSave/handleSaveApply and discarded user edits in
		// other sections. The user must press Save & Apply (or Save) to commit.
		ui.addNotification(
			null,
			E('p', {}, _('Импорт добавлен в черновик. Нажмите «Save & Apply» чтобы применить изменения.')),
			'info'
		);
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

	// Per-row Export JSON button. Rendered inline by GridSection as a column
	// (form.Button is the LuCI primitive for non-input action cells). Click
	// dispatches export_section RPC and opens the modal with the JSON.
	o = s.option(form.Button, '_export', _('JSON'));
	o.editable = true;
	o.modalonly = false;
	o.inputtitle = _('Export');
	o.inputstyle = 'action';
	o.onclick = function (ev, section_id) {
		SbImpInbound.jsonExportInbound(section_id);
		return false;
	};

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
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isPort(value);
	};

	// direct / shadowsocks
	o = s.option(form.ListValue, 'network', _('Network'));
	o.modalonly = true;
	o.value('', _('Both (tcp+udp)'));
	o.value('tcp', 'tcp');
	o.value('udp', 'udp');
	o.depends('protocol', 'direct');
	o.depends('protocol', 'shadowsocks');

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

	// Shadowsocks multi-user. Each entry: name:password.
	// When at least one valid entry is present, top-level server_password
	// is dropped and sing-box receives a users[] block.
	o = s.option(form.DynamicList, 'ss_user', _('Users'));
	o.modalonly = true;
	o.placeholder = 'alice:password';
	o.description = _('Multi-user shadowsocks. One entry per user, formatted as ' +
		'"name:password". When non-empty, the single-user password above is ignored.');
	o.depends('protocol', 'shadowsocks');

	// users (vless/vmess/trojan/hysteria2)
	o = s.option(form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends('protocol', 'vless');
	o.depends('protocol', 'vmess');
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isUuid(value);
	};
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

	// Multi-user vmess/vless. Each entry is colon-separated:
	//   VMess: name:uuid          or name:uuid:alterId
	//   VLESS: name:uuid          or name:uuid:flow
	// When non-empty, the section-level server_uuid / vmess_alter_id /
	// vless_flow are dropped (sing-box rejects both at once).
	o = s.option(form.DynamicList, 'inbound_user', _('Users'));
	o.modalonly = true;
	o.placeholder = 'alice:550e8400-e29b-41d4-a716-446655440000';
	o.description = _('Multi-user list. Each entry colon-separated: ' +
		'VMess "name:uuid" or "name:uuid:alterId"; VLESS "name:uuid" or ' +
		'"name:uuid:flow" (use "none" or omit to skip flow). ' +
		'When non-empty, the single-user UUID / Alter ID / Flow above are ignored.');
	o.depends('protocol', 'vmess');
	o.depends('protocol', 'vless');

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
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isHost(value);
	};
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
	o.validate = function (sid, value) {
		// LuCI DynamicList passes either the current scalar input or, when
		// the user has typed nothing, an empty string. Treat empty input as
		// pending edit (allow) — only block when there are committed values
		// and *all* are blank. The list value array lives on this.formvalue.
		var fv;
		try { fv = this.formvalue(sid); } catch (e) { fv = value; }
		if (fv === null || fv === undefined) return true;
		if (Array.isArray(fv) && fv.length === 0) return true;
		if (typeof fv === 'string' && fv === '') return true;
		return SbValidators.isAlpnNonEmpty(fv);
	};

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
	o.validate = function (sid, value) {
		// Only ws transport mandates a non-empty path; the validator returns
		// true for every other transport. Read the live transport selection
		// off the section so the check follows the form state.
		var transport;
		try { transport = this.section.formvalue(sid, 'transport'); }
		catch (e) { transport = null; }
		return SbValidators.requiresWsPath(transport, value || '');
	};
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
	o.depends('protocol', 'shadowsocks');

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

return L.Class.extend({
	SB_INBOUND_PROTOCOLS: SB_INBOUND_PROTOCOLS,
	openJsonImportModal:  openJsonImportModal,
	buildInboundsMap:     buildInboundsMap,
});
