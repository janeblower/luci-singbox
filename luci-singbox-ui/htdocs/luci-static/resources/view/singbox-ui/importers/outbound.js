'use strict';
'require uci';
'require ui';
'require view.singbox-ui.importers.inbound as SbImpInbound';
'require view.singbox-ui.importers.transport as SbTransport';

// Constrained to the proxy protocols outbound.uc build_constructor_for()
// actually emits. `direct`/`interface`/`url`/`subscription` are UI-only
// shapes managed via dedicated fields, not by the JSON importer.
var SB_OUTBOUND_KNOWN = {
	'vless': true, 'vmess': true, 'trojan': true, 'hysteria2': true,
	'shadowsocks': true, 'tuic': true, 'anytls': true,
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
			f.obfs_type     = o.obfs.type;
			f.obfs_password = o.obfs.password || '';
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
	SbTransport.parseTransport(o, f);
	out.ok = true;
	return out;
}

// Symmetric wrapper: importers/outbound.js exposes the same export entrypoint
// as inbound.js so callers can stay protocol-scoped. The modal itself is
// shared (defined in importers/inbound.js) to keep one copy of the Copy /
// clipboard-fallback logic.
function jsonExportOutbound(name) {
	return SbImpInbound.jsonExportOutbound(name);
}

// E2: share-link import wrapper.
// Pure-JS parsing for client-side pre-fill; ucode parse_proxy_url is the
// source of truth at config-generation time (rpcd/build path).
// Both parsers must agree on field names so UCI sections emit correctly.
function shareLinkImport(url) {
	try {
		return _shareLinkImport(url);
	} catch (e) {
		// Defense in depth: a malformed link that slips past safeDecode must
		// still return a structured error instead of propagating to onImport.
		return { ok: false, errors: [_('Cannot parse link: ') + (e && e.message ? e.message : String(e))] };
	}
}
function _shareLinkImport(url) {
	// decodeURIComponent throws URIError on malformed %-escapes; a pasted
	// share-link with a broken fragment must surface a clean error, not crash
	// the import modal (spec S2-10). safeDecode returns the raw token on failure.
	function safeDecode(s) {
		if (s == null) return '';
		try { return decodeURIComponent(s); } catch (e) { return String(s); }
	}
	var schemes = ['vless', 'shadowsocks', 'trojan', 'hysteria2'];
	var scheme = (url.split(':')[0] || '').toLowerCase();
	if (scheme === 'ss')  scheme = 'shadowsocks';
	if (scheme === 'hy2') scheme = 'hysteria2';
	if (schemes.indexOf(scheme) === -1)
		return { ok: false, errors: [_('Unsupported scheme: ') + scheme] };

	var match;
	if (scheme === 'vless') {
		match = url.match(/^vless:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse vless URL')] };
		var params = {};
		if (match[4]) match[4].split('&').forEach(function(p) {
			var kv = p.split('='); params[safeDecode(kv[0])] = safeDecode(kv[1] || '');
		});
		var f = {
			type: 'vless',
			server: match[2], server_port: +match[3],
			server_uuid: safeDecode(match[1]),
		};
		if (params.sni)         f.tls_server_name = params.sni;
		if (params.flow)        f.vless_flow       = params.flow;
		if (params.security)    f.security         = params.security;
		if (params.fp)          f.utls_fingerprint = params.fp;
		if (params.pbk)         f.reality_public_key = params.pbk;
		if (params.sid)         f.reality_short_id   = params.sid;
		if (params.type)        f.transport        = params.type;
		if (params.path)        f.transport_path   = params.path;
		if (params.serviceName) f.transport_service_name = params.serviceName;
		return { ok: true, fields: f };
	}
	if (scheme === 'trojan') {
		match = url.match(/^trojan:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse trojan URL')] };
		return { ok: true, fields: {
			type: 'trojan',
			server: match[2], server_port: +match[3],
			server_password: safeDecode(match[1]),
		} };
	}
	if (scheme === 'hysteria2') {
		match = url.match(/^(?:hysteria2|hy2):\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse hysteria2 URL')] };
		var hparams = {};
		if (match[4]) match[4].split('&').forEach(function(p) {
			var kv = p.split('='); hparams[safeDecode(kv[0])] = safeDecode(kv[1] || '');
		});
		var hf = {
			type: 'hysteria2',
			server: match[2], server_port: +match[3],
			server_password: safeDecode(match[1]),
		};
		if (hparams.sni) hf.tls_server_name = hparams.sni;
		if (hparams.obfs === 'salamander') {
			hf.obfs_type     = 'salamander';
			hf.obfs_password = hparams['obfs-password'] || '';
		}
		return { ok: true, fields: hf };
	}
	if (scheme === 'shadowsocks') {
		// SIP002 links commonly carry ?plugin=name;opts before the #tag. The
		// query group (?:\?([^#]*))? mirrors vless/trojan/hysteria2; without it
		// the whole link failed to match and was rejected (audit 9.3). The host
		// alternative also excludes '?' so the query is not swallowed into it.
		match = url.match(/^ss:\/\/(?:([^@#?]+)@)?(\[[0-9a-fA-F:]+\]|[^:#?]+):(\d+)(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse shadowsocks URL')] };
		var userinfo = match[1] ? safeDecode(match[1]) : '';
		var mp = userinfo.split(':');
		if (mp.length < 2 && /^[A-Za-z0-9+/=_-]+$/.test(userinfo)) {
			// SIP002 legacy: userinfo is base64(method:password). Try decode.
			try {
				var b64 = userinfo.replace(/-/g, '+').replace(/_/g, '/');
				var decoded = atob(b64);
				mp = decoded.split(':');
			} catch (e) { /* keep plain mp */ }
		}
		var ssf = {
			type: 'shadowsocks',
			server: match[2], server_port: +match[3],
			shadowsocks_method:  mp[0] || '2022-blake3-aes-128-gcm',
			server_password:     mp.slice(1).join(':'),
		};
		// SIP002 ?plugin=name;opt=val;... → UCI plugin / plugin_opts (the field
		// names the shadowsocks descriptor and backend sharelink.uc both use).
		// First ';'-segment is the plugin name, remainder is the opts string —
		// matching parse_ss() in sharelink.uc so client pre-fill agrees with the
		// config-generation parser.
		if (match[4]) {
			var qp = {};
			match[4].split('&').forEach(function (p) {
				var kv = p.split('='); qp[safeDecode(kv[0])] = safeDecode(kv.slice(1).join('='));
			});
			if (qp.plugin) {
				var semi = qp.plugin.indexOf(';');
				ssf.plugin = (semi >= 0) ? qp.plugin.slice(0, semi) : qp.plugin;
				if (semi >= 0 && semi + 1 < qp.plugin.length)
					ssf.plugin_opts = qp.plugin.slice(semi + 1);
			}
		}
		return { ok: true, fields: ssf };
	}
	return { ok: false, errors: [_('Internal: unhandled scheme')] };
}

return L.Class.extend({
    SB_OUTBOUND_KNOWN:  SB_OUTBOUND_KNOWN,
    jsonImportOutbound: jsonImportOutbound,
    jsonExportOutbound: jsonExportOutbound,
    shareLinkImport:    shareLinkImport,
});
