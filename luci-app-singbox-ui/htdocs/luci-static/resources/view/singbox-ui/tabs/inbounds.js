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
	['mixed',       'Mixed (HTTP + SOCKS5)'],
	['shadowsocks', 'Shadowsocks'],
	['vless',       'VLESS'],
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

	// E2: register only the basic tab here. Shared tabs (TLS/Transport/
	// Multiplex/Dial) are created on demand by descriptor_form.applyMaterialized
	// AFTER fields are attached, so LuCI's tab-disabled heuristic (which fires
	// at tab-creation time based on then-known field set) doesn't lock them
	// disabled before fields arrive.
	s.tab('basic', _('Basic'));

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

	o = s.taboption('basic', form.DummyValue, '_address', _('Address'));
	o.modalonly = false;
	o.editable  = false;
	o.cfgvalue  = function (section_id) {
		var p = uci.get('singbox-ui', section_id, 'protocol') || '';
		if (p === 'tun') return uci.get('singbox-ui', section_id, 'interface_name') || 'singbox-tun';
		var listen = uci.get('singbox-ui', section_id, 'listen')      || '::';
		var port   = uci.get('singbox-ui', section_id, 'listen_port') || '—';
		return listen + ':' + port;
	};

	// E2: all inbound types are now descriptor-driven via applyMaterialized().
	// The hand-coded TUN / TProxy / Direct blocks have been removed — their
	// fields live in protocols/tun.uc, protocols/tproxy.uc, protocols/direct.uc
	// and are served by the protocol_schema RPC.
	var inboundSchema = (window.singboxUiSchemaCache || {}).inbound || {};
	SB_INBOUND_PROTOCOLS.forEach(function (entry) {
		var protoName = entry[0];
		var mat = inboundSchema[protoName];
		if (mat) descriptor_form.applyMaterialized(s, 'inbound', protoName, mat);
	});

	return m;
}

return L.Class.extend({
	SB_INBOUND_PROTOCOLS: SB_INBOUND_PROTOCOLS,
	openJsonImportModal:  openJsonImportModal,
	buildInboundsMap:     buildInboundsMap,
});
