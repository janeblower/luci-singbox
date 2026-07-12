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
	// query(str) — the shared ?a=b&c=d splitter every scheme branch below uses.
	function query(s) {
		var out = {};
		if (s) s.split('&').forEach(function(p) {
			var kv = p.split('=');
			out[safeDecode(kv[0])] = safeDecode(kv.slice(1).join('='));
		});
		return out;
	}
	// Providers emit insecure=yes / allowInsecure=on as readily as =1
	// (mirrors sharelink_map.is_true).
	function isTrue(v) {
		if (v == null) return false;
		var s = String(v).toLowerCase();
		return s === '1' || s === 'true' || s === 'yes' || s === 'on';
	}
	// The set of values sing-box's utls.fingerprint accepts; anything else is a
	// fatal config error, so normalise to chrome (mirrors sharelink_map.normalize_fp).
	var UTLS = ['chrome', 'firefox', 'edge', 'safari', '360', 'ios', 'android',
	            'randomized', 'randomizedalpn', 'randomizednoalpn'];
	function normFp(v) {
		if (!v) return '';
		return (UTLS.indexOf(String(v).toLowerCase()) >= 0) ? String(v).toLowerCase() : 'chrome';
	}

	var schemes = ['vless', 'vmess', 'shadowsocks', 'trojan', 'hysteria2',
	               'tuic', 'anytls', 'hysteria'];
	var scheme = (url.split(':')[0] || '').toLowerCase();
	if (scheme === 'ss')  scheme = 'shadowsocks';
	if (scheme === 'hy2') scheme = 'hysteria2';
	if (scheme === 'hy')  scheme = 'hysteria';
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
		// The trailing slash before the query (host:443/?type=ws) is legal and
		// common; rejecting it made the UI refuse links the backend accepts.
		match = url.match(/^vless:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse vless URL')] };
		var params = query(match[4]);
		// sing-box only knows the xtls-rprx-vision flow (mirror parse_vless).
		if (params.flow && params.flow !== 'xtls-rprx-vision')
			return { ok: false, errors: [_('Unsupported vless flow: ') + params.flow] };
		var f = {
			type: 'vless',
			server: match[2], server_port: +match[3],
			server_uuid: safeDecode(match[1]),
		};
		var vsni = params.sni || params.peer || '';
		var vfp  = normFp(params.fp);
		if (!vfp && (params.security === 'reality' || params.pbk)) vfp = 'chrome';
		if (vsni)               f.tls_server_name = vsni;
		if (params.flow)        f.vless_flow       = params.flow;
		if (vfp)                f.utls_fingerprint = vfp;
		if (params.alpn)        f.tls_alpn = params.alpn.split(',').filter(Boolean);
		// Mirror backend h_tls_security: a reality block (public_key + short_id)
		// is emitted ONLY when pbk is present. reality without a public key is
		// fatal in sing-box, so security=reality without pbk degrades to plain
		// TLS instead of poisoning the draft with a dangling short_id.
		if (params.security === 'reality' && params.pbk) {
			f.security           = 'reality';
			f.reality_public_key = params.pbk;
			if (params.sid)      f.reality_short_id = params.sid;
		} else if (params.security === 'tls' || params.security === 'reality' ||
		           params.security === 'xtls') {
			f.security = 'tls';
		} else if (!params.security && (vsni || params.alpn || vfp || params.pbk)) {
			// Auto-TLS: a link with TLS-only params but no security= is a TLS link.
			// Treating it as plaintext produced a draft that could never connect.
			f.security = 'tls';
		}
		if (f.security && isTrue(params.allowInsecure || params.insecure))
			f.tls_insecure = '1';
		if (params.type)        f.transport        = params.type;
		if (params.path)        f.transport_path   = params.path;
		if (params.host)        f.transport_host   = params.host;
		if (params.serviceName) f.transport_service_name = params.serviceName;
		return { ok: true, fields: f };
	}
	if (scheme === 'trojan') {
		match = url.match(/^trojan:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse trojan URL')] };
		// Parse the query like vless/hysteria2 — these were silently dropped, so a
		// trojan link with sni/transport/TLS imported as a bare host:port draft
		// that diverged from what the backend parse_trojan yields for the same URL.
		var tparams = query(match[4]);
		var tf = {
			type: 'trojan',
			server: match[2], server_port: +match[3],
			server_password: safeDecode(match[1]),
		};
		if (tparams.sni || tparams.peer)
			tf.tls_server_name = tparams.sni || tparams.peer;
		if (tparams.type)        tf.transport              = tparams.type;
		if (tparams.path)        tf.transport_path         = tparams.path;
		if (tparams.host)        tf.transport_host         = tparams.host;
		if (tparams.serviceName) tf.transport_service_name = tparams.serviceName;
		if (normFp(tparams.fp))  tf.utls_fingerprint       = normFp(tparams.fp);
		if (isTrue(tparams.allowInsecure) || isTrue(tparams.allowinsecure) ||
		    isTrue(tparams.insecure))
			tf.tls_insecure = '1';
		return { ok: true, fields: tf };
	}
	if (scheme === 'hysteria2') {
		match = url.match(/^(?:hysteria2|hy2):\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
		if (!match) return { ok: false, errors: [_('Cannot parse hysteria2 URL')] };
		var hparams = query(match[4]);
		var hf = {
			type: 'hysteria2',
			server: match[2], server_port: +match[3],
			server_password: safeDecode(match[1]),
		};
		if (hparams.sni) hf.tls_server_name = hparams.sni;
		if (isTrue(hparams.insecure) || isTrue(hparams.allowInsecure))
			hf.tls_insecure = '1';
		if (hparams.upmbps)   hf.up_mbps   = hparams.upmbps;
		if (hparams.downmbps) hf.down_mbps = hparams.downmbps;
		if (hparams.network)  hf.network   = hparams.network;
		if (hparams.obfs === 'salamander') {
			hf.obfs_type     = 'salamander';
			hf.obfs_password = hparams['obfs-password'] || '';
		}
		return { ok: true, fields: hf };
	}
	// tuic / anytls / hysteria(v1): the backend has parsed these all along; the
	// UI silently refused them, so a pasted link could not be imported at all.
	if (scheme === 'tuic' || scheme === 'anytls' || scheme === 'hysteria') {
		// Userinfo is optional (hysteria v1 may carry its token in ?auth=), so
		// try the with-userinfo shape first and fall back to a bare host:port.
		var uinfo = '', host, port, qs;
		match = url.match(/^[a-z0-9]+:\/\/([^@]+)@(\[[0-9a-fA-F:]+\]|[^:@/?#]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
		if (match) {
			uinfo = safeDecode(match[1]);
			host = match[2]; port = +match[3]; qs = match[4];
		} else {
			match = url.match(/^[a-z0-9]+:\/\/(\[[0-9a-fA-F:]+\]|[^:@/?#]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
			if (!match) return { ok: false, errors: [_('Cannot parse link: ') + scheme] };
			host = match[1]; port = +match[2]; qs = match[3];
		}
		var qp = query(qs);
		var xf = { type: scheme, server: host, server_port: port };
		// TLS is mandatory for all three (QUIC/TLS transports).
		xf.security = 'tls';
		xf.tls_server_name = qp.sni || qp.peer || host;
		if (isTrue(qp.insecure) || isTrue(qp.allow_insecure) || isTrue(qp.allowInsecure))
			xf.tls_insecure = '1';
		if (qp.alpn) xf.tls_alpn = qp.alpn.split(',').filter(Boolean);

		if (scheme === 'tuic') {
			var ci = uinfo.indexOf(':');
			if (ci < 0) return { ok: false, errors: [_('tuic link needs uuid:password')] };
			xf.server_uuid     = uinfo.slice(0, ci);
			xf.server_password = uinfo.slice(ci + 1);
			if (!xf.server_uuid || !xf.server_password)
				return { ok: false, errors: [_('tuic link needs uuid:password')] };
			if (qp.congestion_control) xf.congestion_control = qp.congestion_control;
			if (qp.udp_relay_mode)     xf.udp_relay_mode     = qp.udp_relay_mode;
		} else if (scheme === 'anytls') {
			var ai = uinfo.indexOf(':');
			xf.server_password = (ai >= 0) ? uinfo.slice(ai + 1) : uinfo;
			if (!xf.server_password)
				return { ok: false, errors: [_('anytls link is missing the password')] };
		} else {
			// hysteria v1: the auth token rides in the userinfo or in ?auth=.
			var auth = qp.auth || uinfo;
			if (auth) xf.hysteria_auth_str = auth;
			if (qp.upmbps || qp.up)     xf.up_mbps   = qp.upmbps   || qp.up;
			if (qp.downmbps || qp.down) xf.down_mbps = qp.downmbps || qp.down;
			if (qp.obfs) xf.obfs = qp.obfs;
		}
		return { ok: true, fields: xf };
	}
	if (scheme === 'shadowsocks') {
		// SIP002 links commonly carry ?plugin=name;opts before the #tag. The
		// query group (?:\?([^#]*))? mirrors vless/trojan/hysteria2; without it
		// the whole link failed to match and was rejected (audit 9.3). The host
		// alternative also excludes '?' so the query is not swallowed into it.
		match = url.match(/^ss:\/\/(?:([^@#?]+)@)?(\[[0-9a-fA-F:]+\]|[^:#?]+):(\d+)\/?(?:\?([^#]*))?(?:#(.*))?$/);
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
		// ?plugin-opts= carries the opts on its own when present; otherwise they
		// are the tail of ?plugin=name;opts (mirrors parse_ss).
		if (match[4]) {
			var ssq = query(match[4]);
			var pl = ssq.plugin || '', po = ssq['plugin-opts'] || '';
			if (pl && !po) {
				var semi = pl.indexOf(';');
				if (semi >= 0) { po = pl.slice(semi + 1); pl = pl.slice(0, semi); }
			}
			if (pl) ssf.plugin = pl;
			if (po) ssf.plugin_opts = po;
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
