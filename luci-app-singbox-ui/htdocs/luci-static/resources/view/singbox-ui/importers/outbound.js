'use strict';
'require uci';
'require ui';

// Constrained to the proxy protocols outbound.uc build_constructor_for()
// actually emits. `direct`/`interface`/`url`/`subscription` are UI-only
// shapes managed via dedicated fields, not by the JSON importer.
var SB_OUTBOUND_KNOWN = {
	'vless': true, 'vmess': true, 'trojan': true, 'hysteria2': true,
	'shadowsocks': true, 'tuic': true,
};

function jsonImportOutbound(o) {
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

return L.Class.extend({
    SB_OUTBOUND_KNOWN:  SB_OUTBOUND_KNOWN,
    jsonImportOutbound: jsonImportOutbound,
});
