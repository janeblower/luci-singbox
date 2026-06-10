'use strict';

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

return L.Class.extend({ parseTransport: parseTransport });
