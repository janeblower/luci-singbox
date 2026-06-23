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
	// bad(msg) — abort with a parse error and NO partial fields, consistent
	// with the type/shape rejections above (IMP-1).
	function bad(msg) { out.fields = {}; out.errors.push(msg); return out; }
	f.type = o.type;
	if (o.server)      f.server      = o.server;
	if (o.server_port != null) {
		var sp = SbTransport.parseIntField(o.server_port, 1, 65535);
		if (!sp.ok) return bad(_('Invalid port: ') + o.server_port);
		f.server_port = sp.value;
	}

	if (o.type === 'shadowsocks') {
		if (o.method)   f.shadowsocks_method = o.method;
		if (o.password) f.server_password    = o.password;
	}
	if (o.type === 'vless' || o.type === 'vmess') {
		if (o.uuid) f.server_uuid = o.uuid;
		if (o.flow) f.vless_flow  = o.flow;
		if (o.alter_id != null) {
			var aid = SbTransport.parseIntField(o.alter_id, 0, null);
			if (!aid.ok) return bad(_('Invalid alter_id: ') + o.alter_id);
			f.vmess_alter_id = String(aid.value);
		}
		if (o.security)         f.vmess_security = o.security;
	}
	if (o.type === 'trojan' || o.type === 'hysteria2') {
		if (o.password) f.server_password = o.password;
	}
	if (o.type === 'hysteria2') {
		if (o.up_mbps != null) {
			var up = SbTransport.parseIntField(o.up_mbps, 0, null);
			if (!up.ok) return bad(_('Invalid up_mbps: ') + o.up_mbps);
			f.up_mbps = String(up.value);
		}
		if (o.down_mbps != null) {
			var dn = SbTransport.parseIntField(o.down_mbps, 0, null);
			if (!dn.ok) return bad(_('Invalid down_mbps: ') + o.down_mbps);
			f.down_mbps = String(dn.value);
		}
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
	var schemes = ['vless', 'vmess', 'shadowsocks', 'trojan', 'hysteria2'];
	var scheme = (url.split(':')[0] || '').toLowerCase();
	if (scheme === 'ss')  scheme = 'shadowsocks';
	if (scheme === 'hy2') scheme = 'hysteria2';
	if (schemes.indexOf(scheme) === -1)
		return { ok: false, errors: [_('Unsupported scheme: ') + scheme] };

	if (scheme === 'vmess') {
		// v2rayN vmess:// is base64(JSON). Decode + map to the sing-box outbound
		// shape parse_vmess produces, then reuse jsonImportOutbound's field mapping
		// so client pre-fill agrees with the backend parser.
		var vbody = url.slice('vmess://'.length).split('#')[0].replace(/-/g, '+').replace(/_/g, '/');
		while (vbody.length % 4) vbody += '=';
		var vj;
		try { vj = JSON.parse(atob(vbody)); }
		catch (e) { return { ok: false, errors: [_('Cannot parse vmess URL')] }; }
		if (!vj || typeof vj !== 'object' || Array.isArray(vj))
			return { ok: false, errors: [_('Cannot parse vmess URL')] };
		var vo = {
			type: 'vmess',
			server: String(vj.add || ''),
			server_port: +vj.port || 0,
			uuid: String(vj.id || ''),
			security: vj.scy ? String(vj.scy) : 'auto',
			alter_id: +vj.aid || 0,
		};
		if (!vo.server || !vo.server_port || !vo.uuid)
			return { ok: false, errors: [_('vmess link missing server/port/uuid')] };
		var vnet = String(vj.net || 'tcp');
		var vpath = String(vj.path || ''), vhost = String(vj.host || '');
		if (vnet === 'ws') {
			vo.transport = { type: 'ws' };
			if (vpath) vo.transport.path = vpath;
			if (vhost) vo.transport.headers = { Host: vhost };
		} else if (vnet === 'grpc') {
			vo.transport = { type: 'grpc' };
			if (vpath) vo.transport.service_name = vpath;
		} else if (vnet === 'h2' || vnet === 'http') {
			vo.transport = { type: 'http' };
			if (vpath) vo.transport.path = vpath;
			if (vhost) vo.transport.host = [ vhost ];
		}
		if (String(vj.tls || '') === 'tls')
			vo.tls = { enabled: true, server_name: String(vj.sni || '') || vhost || vo.server };
		return jsonImportOutbound(vo);
	}

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
		if (params.fp)          f.utls_fingerprint = params.fp;
		// Mirror backend h_tls_security: a reality block (public_key + short_id)
		// is emitted ONLY when pbk is present. reality without a public key is
		// fatal in sing-box, so security=reality without pbk degrades to plain
		// TLS instead of poisoning the draft with a dangling short_id.
		if (params.security === 'reality' && params.pbk) {
			f.security           = 'reality';
			f.reality_public_key = params.pbk;
			if (params.sid)      f.reality_short_id = params.sid;
		} else if (params.security === 'tls' || params.security === 'reality') {
			f.security = 'tls';
		}
		if (params.type)        f.transport        = params.type;
		if (params.path)        f.transport_path   = params.path;
		if (params.serviceName) f.transport_service_name = params.serviceName;
		return { ok: true, fields: f };
	}
	if (scheme === 'trojan') {
		match = url.match(/^trojan:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse trojan URL')] };
		// Parse the query like vless/hysteria2 — these were silently dropped, so a
		// trojan link with sni/transport/TLS imported as a bare host:port draft
		// that diverged from what the backend parse_trojan yields for the same URL.
		var tparams = {};
		if (match[4]) match[4].split('&').forEach(function(p) {
			var kv = p.split('='); tparams[safeDecode(kv[0])] = safeDecode(kv[1] || '');
		});
		var tf = {
			type: 'trojan',
			server: match[2], server_port: +match[3],
			server_password: safeDecode(match[1]),
		};
		if (tparams.sni)         tf.tls_server_name        = tparams.sni;
		if (tparams.type)        tf.transport              = tparams.type;
		if (tparams.path)        tf.transport_path         = tparams.path;
		if (tparams.host)        tf.transport_host         = tparams.host;
		if (tparams.serviceName) tf.transport_service_name = tparams.serviceName;
		if (tparams.allowInsecure === '1' || tparams.allowInsecure === 'true' ||
		    tparams.insecure === '1' || tparams.insecure === 'true')
			tf.tls_insecure = '1';
		return { ok: true, fields: tf };
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
		// Mirror backend parse_ss: a credential-less link (empty method or
		// password) is rejected, not fabricated into a default-method draft.
		var ssMethod = mp[0] || '';
		var ssPass   = mp.slice(1).join(':');
		if (!ssMethod.length || !ssPass.length)
			return { ok: false, errors: [_('Shadowsocks link is missing method/password')] };
		var ssf = {
			type: 'shadowsocks',
			server: match[2], server_port: +match[3],
			shadowsocks_method:  ssMethod,
			server_password:     ssPass,
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
