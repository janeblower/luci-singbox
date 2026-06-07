'use strict';
'require form';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.validators as SbValidators';
'require view.singbox-ui.importers.outbound as SbImpOutbound';
'require view.singbox-ui.tabs.inbounds as SbTabInbounds';

var addRenameField      = SbCommon.addRenameField;
var openJsonImportModal = SbTabInbounds.openJsonImportModal;

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

	// C2.2.7: group the ~50 modal options into topical tabs so the modal
	// stops scrolling forever. Tab assignment is purely visual — the
	// depends()/validate()/write()/cfgvalue() chains below are unchanged.
	s.tab('basic',       _('Basic'));
	s.tab('credentials', _('Credentials'));
	s.tab('tls',         _('TLS'));
	s.tab('transport',   _('Transport'));
	s.tab('multiplex',   _('Multiplex'));
	s.tab('advanced',    _('Advanced'));

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
	o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	// Per-row Export JSON button. Mirror of the inbound grid: GridSection
	// renders form.Button as an inline action cell so users get the JSON for
	// the row they clicked, not the whole config.
	o = s.taboption('basic', form.Button, '_export', _('JSON'));
	o.editable = true;
	o.modalonly = false;
	o.inputtitle = _('Export');
	o.inputstyle = 'action';
	o.onclick = function (ev, section_id) {
		SbImpOutbound.jsonExportOutbound(section_id);
		return false;
	};

	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	o.value('vless',        'VLESS');
	o.value('vmess',        'VMess');
	o.value('trojan',       'Trojan');
	o.value('hysteria2',    'Hysteria2');
	o.value('shadowsocks',  'Shadowsocks');
	o.value('tuic',         'TUIC');
	o.value('anytls',       'AnyTLS');
	o.value('interface',    _('Direct (interface)'));
	o.value('url',          _('Share-link URL'));
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	o = s.taboption('basic', form.Value, 'server', _('Server'));
	o.modalonly = true; o.placeholder = 'example.com';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');
	o.depends('type', 'tuic');
	o.depends('type', 'anytls');
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isHost(value);
	};
	o = s.taboption('basic', form.Value, 'server_port', _('Server port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '443';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');
	o.depends('type', 'tuic');
	o.depends('type', 'anytls');
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isPort(value);
	};

	o = s.taboption('credentials', form.Value, 'server_uuid', _('UUID'));
	o.modalonly = true; o.password = true;
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'tuic');
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isUuid(value);
	};
	o = s.taboption('credentials', form.Value, 'server_password', _('Password'));
	o.modalonly = true; o.password = true;
	o.depends('type', 'trojan');
	o.depends('type', 'hysteria2');
	o.depends('type', 'shadowsocks');
	o.depends('type', 'tuic');
	o.depends('type', 'anytls');

	o = s.taboption('credentials', form.ListValue, 'vless_flow', _('Flow'));
	o.value('none', _('None')); o.value('xtls-rprx-vision', 'xtls-rprx-vision');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o = s.taboption('credentials', form.Value, 'vmess_alter_id', _('Alter ID'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '0';
	o.depends('type', 'vmess');
	// vmess_security (cipher) goes to advanced per spec C2.2.7.
	o = s.taboption('advanced', form.ListValue, 'vmess_security', _('Cipher'));
	['auto','none','aes-128-gcm','chacha20-poly1305'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'auto';
	o.depends('type', 'vmess');
	o = s.taboption('credentials', form.ListValue, 'shadowsocks_method', _('Method'));
	['aes-128-gcm','aes-256-gcm','chacha20-ietf-poly1305',
	 '2022-blake3-aes-128-gcm','2022-blake3-aes-256-gcm'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'aes-128-gcm';
	o.depends('type', 'shadowsocks');

	// hysteria2 obfs + bandwidth caps live in advanced per spec C2.2.7.
	o = s.taboption('advanced', form.ListValue, 'hysteria2_obfs_type', _('Obfuscation'));
	o.value('none', _('None')); o.value('salamander', 'salamander');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'hysteria2');
	o = s.taboption('advanced', form.Value, 'hysteria2_obfs_password', _('Obfs password'));
	o.modalonly = true; o.password = true;
	o.depends({ type: 'hysteria2', hysteria2_obfs_type: 'salamander' });
	o = s.taboption('advanced', form.Value, 'up_mbps', _('Up Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('type', 'hysteria2');
	o = s.taboption('advanced', form.Value, 'down_mbps', _('Down Mbps'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('type', 'hysteria2');

	// TLS (vless/vmess/trojan; hysteria2, tuic and anytls are always TLS)
	o = s.taboption('tls', form.ListValue, 'security', _('Security'));
	o.value('none', _('None')); o.value('tls', 'TLS'); o.value('reality', 'Reality');
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	o.depends('type', 'tuic');
	o.depends('type', 'anytls');
	o = s.taboption('tls', form.Value, 'tls_server_name', _('TLS server name'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o.depends({ type: 'tuic', security: 'tls' });
	o.depends({ type: 'anytls', security: 'tls' });
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isHost(value);
	};
	o = s.taboption('tls', form.Flag, 'tls_insecure', _('Allow insecure'));
	o.modalonly = true; o.default = '0';
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o = s.taboption('tls', form.DynamicList, 'tls_alpn', _('ALPN'));
	o.modalonly = true; o.placeholder = 'h2';
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	o.depends('type', 'hysteria2');
	o.validate = function (sid, value) {
		// Per spec C2.2.3: empty ALPN is valid; only validates protocol IDs.
		var fv;
		try { fv = this.formvalue(sid); } catch (e) { fv = value; }
		return SbValidators.validateAlpn(fv);
	};
	o = s.taboption('tls', form.ListValue, 'utls_fingerprint', _('uTLS fingerprint'));
	['','chrome','firefox','safari','edge','random'].forEach(function (v) { o.value(v, v || _('None')); });
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'tls' });
	o.depends({ type: 'vless', security: 'reality' });
	o.depends({ type: 'vmess', security: 'tls' });
	o.depends({ type: 'trojan', security: 'tls' });
	// Reality fields grouped under TLS tab per spec C2.2.7.
	o = s.taboption('tls', form.Value, 'reality_public_key', _('Reality public key'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'reality' });
	o = s.taboption('tls', form.Value, 'reality_short_id', _('Reality short ID'));
	o.modalonly = true;
	o.depends({ type: 'vless', security: 'reality' });

	// transport (vless/vmess/trojan)
	o = s.taboption('transport', form.ListValue, 'transport', _('Transport'));
	['none','ws','grpc','httpupgrade','xhttp','http'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'none';
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');
	// Transport-typed fields must depend on BOTH the outbound type AND the
	// transport selection. Without the type bind, e.g. transport_path leaked
	// onto outbound types that don't expose a transport field (spec C2.2.2).
	o = s.taboption('transport', form.Value, 'transport_path', _('Transport path'));
	o.modalonly = true; o.placeholder = '/';
	['vless','vmess','trojan'].forEach(function (p) {
		o.depends({ type: p, transport: 'ws' });
		o.depends({ type: p, transport: 'httpupgrade' });
		o.depends({ type: p, transport: 'xhttp' });
		o.depends({ type: p, transport: 'http' });
	});
	o.validate = function (sid, value) {
		var transport;
		try { transport = this.section.formvalue(sid, 'transport'); }
		catch (e) { transport = null; }
		return SbValidators.requiresWsPath(transport, value || '');
	};
	o = s.taboption('transport', form.Value, 'transport_host', _('Transport host'));
	o.modalonly = true;
	['vless','vmess','trojan'].forEach(function (p) {
		o.depends({ type: p, transport: 'ws' });
		o.depends({ type: p, transport: 'httpupgrade' });
	});
	o = s.taboption('transport', form.Value, 'transport_service_name', _('gRPC service name'));
	o.modalonly = true;
	['vless','vmess','trojan'].forEach(function (p) {
		o.depends({ type: p, transport: 'grpc' });
	});

	o = s.taboption('transport', form.ListValue, 'transport_xhttp_mode', _('XHTTP mode'));
	o.modalonly = true;
	o.value('auto', 'auto'); o.value('packet-up', 'packet-up');
	o.value('stream-up', 'stream-up'); o.value('stream-one', 'stream-one');
	o.default = 'auto';
	o.depends({ type: 'vless', transport: 'xhttp' });
	o.depends({ type: 'vmess', transport: 'xhttp' });
	o.depends({ type: 'trojan', transport: 'xhttp' });

	o = s.taboption('transport', form.DynamicList, 'transport_hosts', _('HTTP hosts'));
	o.modalonly = true;
	o.depends({ type: 'vless', transport: 'http' });
	o.depends({ type: 'vmess', transport: 'http' });
	o.depends({ type: 'trojan', transport: 'http' });

	// Multiplex
	o = s.taboption('multiplex', form.Flag, 'multiplex_enabled', _('Multiplex'));
	o.modalonly = true;
	o.depends('type', 'vless');
	o.depends('type', 'vmess');
	o.depends('type', 'trojan');

	o = s.taboption('multiplex', form.ListValue, 'multiplex_protocol', _('Multiplex protocol'));
	o.modalonly = true;
	['smux','yamux','h2mux'].forEach(function (v) { o.value(v, v); });
	o.default = 'smux';
	o.depends('multiplex_enabled', '1');

	o = s.taboption('multiplex', form.Value, 'multiplex_max_connections', _('Multiplex max connections'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.taboption('multiplex', form.Value, 'multiplex_min_streams', _('Multiplex min streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.taboption('multiplex', form.Value, 'multiplex_max_streams', _('Multiplex max streams'));
	o.modalonly = true; o.datatype = 'uinteger';
	o.depends('multiplex_enabled', '1');

	o = s.taboption('multiplex', form.Flag, 'multiplex_padding', _('Multiplex padding'));
	o.modalonly = true;
	o.depends('multiplex_enabled', '1');

	// Hysteria2 masquerade — protocol-specific, advanced per spec.
	o = s.taboption('advanced', form.Value, 'hysteria2_masquerade', _('Masquerade URL'));
	o.modalonly = true;
	o.placeholder = 'https://www.example.com';
	o.depends('type', 'hysteria2');

	// TUIC-specific fields (all advanced per spec C2.2.7).
	o = s.taboption('advanced', form.ListValue, 'tuic_congestion', _('Congestion control'));
	o.modalonly = true;
	o.value('', _('Default (cubic)'));
	o.value('cubic',    'cubic');
	o.value('new_reno', 'new_reno');
	o.value('bbr',      'bbr');
	o.depends('type', 'tuic');
	// Non-blocking: softWarnCongestion always returns true; the call exists
	// so an unknown UCI-side value (e.g. paste from a future sing-box release)
	// surfaces a console.warn for debug visibility without breaking saves.
	o.validate = function (sid, value) {
		return SbValidators.softWarnCongestion(value || '');
	};
	o = s.taboption('advanced', form.ListValue, 'tuic_udp_relay_mode', _('UDP relay mode'));
	o.modalonly = true;
	o.value('', _('Default (native)'));
	o.value('native', 'native');
	o.value('quic',   'quic');
	o.depends('type', 'tuic');
	o = s.taboption('advanced', form.Flag, 'tuic_udp_over_stream', _('UDP over stream'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('type', 'tuic');
	o.description = _('Overrides UDP relay mode when enabled.');
	o = s.taboption('advanced', form.Flag, 'tuic_zero_rtt', _('Zero-RTT handshake'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('type', 'tuic');
	o = s.taboption('advanced', form.Value, 'tuic_heartbeat', _('Heartbeat'));
	o.modalonly = true;
	o.placeholder = '10s';
	o.depends('type', 'tuic');

	// AnyTLS-specific fields (no transport / multiplex by spec; advanced tab).
	o = s.taboption('advanced', form.Value, 'anytls_idle_check_interval', _('Idle session check interval'));
	o.modalonly = true;
	o.placeholder = '30s';
	o.depends('type', 'anytls');
	o = s.taboption('advanced', form.Value, 'anytls_idle_timeout', _('Idle session timeout'));
	o.modalonly = true;
	o.placeholder = '30s';
	o.depends('type', 'anytls');
	o = s.taboption('advanced', form.Value, 'anytls_min_idle_session', _('Min idle sessions'));
	o.modalonly = true;
	o.datatype = 'uinteger';
	o.placeholder = '0';
	o.depends('type', 'anytls');

	// Basic-tab fields specific to the non-proxy outbound types
	// (interface / url / subscription). They share the basic tab with
	// type/server/server_port so the form's primary identity stays grouped.
	o = s.taboption('basic', widgets.DeviceSelect, 'interface', _('Interface'));
	o.modalonly = true;
	o.noaliases = true;
	o.depends('type', 'interface');
	o.description = _('For a direct-via-WAN outbound, pick the real WAN device (may differ from "wan").');

	o = s.taboption('basic', form.Value, 'proxy_url', _('URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'vless:// | vmess:// | ss:// | trojan:// | hy2://';
	o.description = _('Share-link URL. Supported schemes: vless://, vmess:// (v2rayN base64-JSON), ss://, trojan://, hy2:// / hysteria2://.');
	o.depends('type', 'url');

	o = s.taboption('basic', form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.ListValue, 'sub_update_via', _('Update via'));
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

	o = s.taboption('basic', form.Value, 'sub_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '3600';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.Flag, 'sub_multi', _('Expand to selector'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.ListValue, 'sub_selector_type', _('Selector type'));
	o.modalonly = true;
	o.value('selector', 'selector');
	o.value('urltest',  'urltest');
	o.default = 'selector';
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Value, 'sub_urltest_url', _('URL-test URL'));
	o.modalonly   = true;
	o.placeholder = 'https://www.gstatic.com/generate_204';
	o.depends({ type: 'subscription', sub_multi: '1', sub_selector_type: 'urltest' });

	return m;
}

return L.Class.extend({
	buildOutboundsMap: buildOutboundsMap,
});
