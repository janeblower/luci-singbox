'use strict';
'require uci';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.importers.transport as SbTransport';

// Constrained to the protocols inbound.uc actually builds — importing
// anything else would create a UCI section that generate.uc silently drops.
var SB_INBOUND_KNOWN = {
	'tproxy': true, 'tun': true, 'direct': true,
	'shadowsocks': true, 'vless': true, 'vmess': true, 'trojan': true,
	'hysteria2': true,
};

function jsonImportInbound(o) {
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
		// Multi-user wins: when `users[]` is present, emit a `ss_user` list
		// and drop the top-level password (sing-box rejects both at once).
		if (Array.isArray(o.users) && o.users.length) {
			var ssu = [];
			for (var si = 0; si < o.users.length; si++) {
				var su = o.users[si] || {};
				if (su.name == null || su.password == null) continue;
				if (!String(su.name).length || !String(su.password).length) continue;
				ssu.push(String(su.name) + ':' + String(su.password));
			}
			if (ssu.length) f.ss_user = ssu;
			else if (o.password) f.server_password = o.password;
		} else if (o.password) {
			f.server_password = o.password;
		}
	}
	if (o.type === 'vless' || o.type === 'vmess'
	    || o.type === 'trojan' || o.type === 'hysteria2') {
		// vmess/vless: when imported JSON carries multi-user `users[]`,
		// emit a `list inbound_user` and drop section-level single-user
		// fields (sing-box rejects both at once).
		if ((o.type === 'vless' || o.type === 'vmess')
		    && Array.isArray(o.users) && o.users.length > 1) {
			var iu = [];
			for (var ui2 = 0; ui2 < o.users.length; ui2++) {
				var pu = o.users[ui2] || {};
				if (pu.uuid == null || !String(pu.uuid).length) continue;
				var nm = (pu.name != null) ? String(pu.name) : '';
				if (!nm.length) continue;
				var entry = nm + ':' + String(pu.uuid);
				if (o.type === 'vmess') {
					// Accept both spec-correct camelCase `alterId` and
					// legacy snake_case `alter_id` for paste-compat.
					var aid2 = (pu.alterId != null) ? pu.alterId : pu.alter_id;
					if (aid2 != null) entry += ':' + String(aid2);
				} else if (o.type === 'vless') {
					if (pu.flow != null && String(pu.flow).length
					    && String(pu.flow) !== 'none')
						entry += ':' + String(pu.flow);
				}
				iu.push(entry);
			}
			if (iu.length) f.inbound_user = iu;
		} else {
			var u = (o.users && o.users[0]) || {};
			if (u.uuid)     f.server_uuid     = u.uuid;
			if (u.password) f.server_password = u.password;
			if (u.flow)     f.vless_flow      = u.flow;
			// sing-box 1.12 docs spec the camelCase `alterId`; accept the
			// legacy snake_case for paste-compat.
			var aid = (u.alterId != null) ? u.alterId : u.alter_id;
			if (aid != null) f.vmess_alter_id = String(aid);
		}
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
	SbTransport.parseTransport(o, f);
	if (o.type === 'hysteria2') {
		if (o.obfs && o.obfs.type) {
			f.obfs_type     = o.obfs.type;
			f.obfs_password = o.obfs.password || '';
		}
		if (o.up_mbps   != null) f.up_mbps   = String(o.up_mbps);
		if (o.down_mbps != null) f.down_mbps = String(o.down_mbps);
	}
	out.ok = true;
	return out;
}

// openJsonExportModal(kind, name) — shared between inbound/outbound export.
// Fetches the section's sing-box JSON via the export_section RPC and shows it
// in a modal with a Copy button. On RPC error the modal renders the error
// message instead.
function openJsonExportModal(kind, name) {
	var pre = E('pre', {
		'class': 'cbi-input-textarea sb-json-modal-pre',
		'style': 'max-height:50vh;overflow:auto;white-space:pre-wrap;' +
		         'font-family:monospace;font-size:90%;'
	}, _('Loading…'));
	var status = E('div', { 'class': 'sb-json-modal-status',
		'style': 'margin-top:8px;color:#555;font-size:90%;' });

	// Clipboard helpers now live in lib/common.js (C2.2.6 dedup). showCopyResult
	// stays inline because the status node is local to this modal — the helper
	// just calls back into it.
	function showCopyResult(msg, isErr) {
		status.textContent = msg;
		status.classList.remove('sb-error', 'sb-ok');
		status.classList.add(isErr ? 'sb-error' : 'sb-ok');
	}
	function onCopyClick() {
		SbCommon.copyToClipboard(pre.textContent || '', showCopyResult);
	}

	ui.showModal(_('Export JSON') + ' — ' + kind + ' ' + name, [
		pre, status,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': onCopyClick },
				_('Copy'))
		])
	]);

	SbRpc.callExportSection(kind, name).then(function (res) {
		if (!res || res.status !== 'ok') {
			pre.textContent = _('Error: ') + ((res && res.message) || _('unknown error'));
			return;
		}
		pre.textContent = JSON.stringify(res.section, null, 2);
	}, function (err) {
		pre.textContent = _('RPC failed: ') + (err && err.message ? err.message : String(err));
	});
}

function jsonExportInbound(name)  { openJsonExportModal('inbound',  name); }
function jsonExportOutbound(name) { openJsonExportModal('outbound', name); }

return L.Class.extend({
    SB_INBOUND_KNOWN:    SB_INBOUND_KNOWN,
    jsonImportInbound:   jsonImportInbound,
    openJsonExportModal: openJsonExportModal,
    jsonExportInbound:   jsonExportInbound,
    jsonExportOutbound:  jsonExportOutbound,
});
