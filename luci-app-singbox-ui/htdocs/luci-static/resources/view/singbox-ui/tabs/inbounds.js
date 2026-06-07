'use strict';
'require form';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.validators as SbValidators';
'require view.singbox-ui.importers.inbound as SbImpInbound';
'require view.singbox-ui.importers.outbound as SbImpOutbound';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';

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
			E('p', {}, _('Import staged as draft. Press "Save & Apply" to commit the changes.')),
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

	// C2.2.7: group the ~50 modal options into topical tabs so the modal
	// stops scrolling forever. Tab assignment is purely visual — the
	// depends()/validate()/write()/cfgvalue() chains below are unchanged.
	s.tab('basic',       _('Basic'));
	s.tab('credentials', _('Credentials'));
	s.tab('tls',         _('TLS'));
	s.tab('transport',   _('Transport'));
	s.tab('multiplex',   _('Multiplex'));
	s.tab('advanced',    _('Advanced'));

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
	o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
	o.default = '1'; o.editable = true;

	// Per-row Export JSON button. Rendered inline by GridSection as a column
	// (form.Button is the LuCI primitive for non-input action cells). Click
	// dispatches export_section RPC and opens the modal with the JSON.
	o = s.taboption('basic', form.Button, '_export', _('JSON'));
	o.editable = true;
	o.modalonly = false;
	o.inputtitle = _('Export');
	o.inputstyle = 'action';
	o.onclick = function (ev, section_id) {
		SbImpInbound.jsonExportInbound(section_id);
		return false;
	};

	o = s.taboption('basic', form.ListValue, 'protocol', _('Protocol'));
	SB_INBOUND_PROTOCOLS.forEach(function (p) { o.value(p[0], _(p[1])); });
	o.default = 'tproxy'; o.rmempty = false;

	o = s.taboption('basic', form.Value, 'listen', _('Listen address'));
	o.modalonly = true; o.placeholder = '::';
	o.depends('protocol', 'direct');
	o.depends('protocol', 'tproxy');

	o = s.taboption('basic', form.Value, 'listen_port', _('Listen port'));
	o.modalonly = true; o.datatype = 'port'; o.placeholder = '7893';
	o.depends('protocol', 'direct');
	o.depends('protocol', 'tproxy');
	o.validate = function (sid, value) {
		if (value === null || value === undefined || value === '') return true;
		return SbValidators.isPort(value);
	};

	// direct only (shadowsocks network is descriptor-owned)
	o = s.taboption('basic', form.ListValue, 'network', _('Network'));
	o.modalonly = true;
	o.value('', _('Both (tcp+udp)'));
	o.value('tcp', 'tcp');
	o.value('udp', 'udp');
	o.depends('protocol', 'direct');

	o = s.taboption('basic', form.Flag, 'dns_listener', _('Hijack DNS'));
	o.modalonly = true;
	o.default = '1';
	o.depends('protocol', 'direct');
	o.description = _('Auto-emits a hijack-dns route rule for this inbound.');

	// tproxy
	o = s.taboption('basic', widgets.DeviceSelect, 'interface', _('Interfaces (nft)'));
	o.modalonly = true; o.noaliases = true; o.multiple = true; o.placeholder = 'br-lan';
	o.depends('protocol', 'tproxy');
	o = s.taboption('basic', form.Flag, 'hijack_dns', _('Hijack DNS'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');
	o = s.taboption('basic', form.Flag, 'tcp_fast_open', _('TCP Fast Open'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');
	o = s.taboption('basic', form.Flag, 'udp_fragment', _('UDP fragment'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tproxy');

	// tproxy + tun: nft rules
	o = s.taboption('basic', form.Flag, 'nft_rules', _('Create nftables rules'));
	o.modalonly = true;
	o.depends('protocol', 'tproxy');
	o.depends('protocol', 'tun');

	// tun
	o = s.taboption('basic', form.Value, 'interface_name', _('TUN interface name'));
	o.modalonly = true; o.placeholder = 'singbox-tun';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.Value, 'inet4_address', _('IPv4 address'));
	o.modalonly = true; o.datatype = 'cidr4'; o.placeholder = '172.19.0.1/30';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.Value, 'inet6_address', _('IPv6 address'));
	o.modalonly = true; o.datatype = 'cidr6';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.Value, 'mtu', _('MTU'));
	o.modalonly = true; o.datatype = 'uinteger'; o.placeholder = '9000';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.ListValue, 'stack', _('Stack'));
	['system', 'gvisor', 'mixed'].forEach(function (v) { o.value(v, v); });
	o.modalonly = true; o.default = 'mixed';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.Flag, 'auto_route', _('Auto route'));
	o.modalonly = true; o.default = '1';
	o.depends('protocol', 'tun');
	o = s.taboption('basic', form.Flag, 'strict_route', _('Strict route'));
	o.modalonly = true; o.default = '0';
	o.depends('protocol', 'tun');

	// D2: descriptor-driven UI for the 5 proxy inbound types. tproxy/tun/direct
	// are infrastructure types and keep their hand-coded blocks above.
	var inboundSchema = (window.singboxUiSchemaCache || {}).inbound || {};
	Object.keys(inboundSchema).forEach(function(protoName) {
		descriptor_form.applyDescriptor(s, 'inbound', protoName, inboundSchema[protoName]);
	});

	return m;
}

return L.Class.extend({
	SB_INBOUND_PROTOCOLS: SB_INBOUND_PROTOCOLS,
	openJsonImportModal:  openJsonImportModal,
	buildInboundsMap:     buildInboundsMap,
});
