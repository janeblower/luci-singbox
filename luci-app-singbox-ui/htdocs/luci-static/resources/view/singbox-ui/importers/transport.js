'use strict';

// parseIntField — coerce a pasted numeric field with validation (IMP-1).
// Unary + on a non-numeric paste (e.g. "listen_port":"eight") yields NaN, which
// the import write path String()'d into the literal "NaN" — silently producing
// a UCI section sing-box later rejects. Returns { ok, value } so the caller can
// push an actionable parse error into the modal instead. `min`/`max` bound the
// accepted range (e.g. 1..65535 for ports); pass null to skip a bound.
function parseIntField(raw, min, max) {
	var n = parseInt(raw, 10);
	if (!isFinite(n)) return { ok: false };
	// Reject "12abc" / objects: parseInt would accept the numeric prefix, so
	// re-stringify and compare to catch trailing garbage.
	if (String(n) !== String(raw).trim()) return { ok: false };
	if (min != null && n < min) return { ok: false };
	if (max != null && n > max) return { ok: false };
	return { ok: true, value: n };
}

// Shared transport-field parser for the inbound and outbound JSON importers
// (spec S2-QUAL). Both importers had a ~1:1 copy of this block; mutating one
// and not the other risked silent divergence. parseTransport(o, f) reads
// o.transport and writes the transport_* fields into f in place.
function parseTransport(o, f) {
	if (!o || !o.transport || !o.transport.type) return f;
	f.transport = o.transport.type;
	if (o.transport.path)         f.transport_path         = o.transport.path;
	if (o.transport.service_name) f.transport_service_name = o.transport.service_name;
	if (o.transport.headers && o.transport.headers.Host)
		f.transport_host = o.transport.headers.Host;
	if (o.transport.host != null) {
		// `http` transport carries an array of vhosts; ws/httpupgrade stays a
		// single scalar. Route each into its own UCI field.
		if (o.transport.type === 'http')
			f.transport_hosts = Array.isArray(o.transport.host)
				? o.transport.host : [ o.transport.host ];
		else
			f.transport_host = Array.isArray(o.transport.host)
				? o.transport.host[0] : o.transport.host;
	}
	if (o.transport.type === 'xhttp' && o.transport.mode)
		f.transport_xhttp_mode = o.transport.mode;
	return f;
}

return L.Class.extend({
	parseIntField:  parseIntField,
	parseTransport: parseTransport,
});
