'use strict';

// Pure-function validators for LuCI form .validate callbacks.
//
// luci-base's own validation.js already ships datatypes for port and host
// (opt.datatype = 'port' / 'host', wired by
// lib/descriptor_form.js::attachValidator) — that used to be reinvented here
// as isPort/isHost/isIPv6Shape, reachable only through a name-mangled string
// map. Only what LuCI has NO datatype for still lives in this file:
//   - uuid — no LuCI datatype for RFC 4122 UUIDs.
//   - url  — no LuCI datatype for http(s):// URLs; also the one validator
//            with a direct call site (tabs/outbounds.js), not just a
//            descriptor `validate:` string.
//   - alpn — no LuCI datatype for a sing-box ALPN protocol list.
// Do not add port/host/IPv6-shape checks back here — that is validation.js's
// job now.
//
// Contract reminder (LuCI form): a .validate callback returns
//   - true (or any truthy non-string) when the input is valid;
//   - a non-empty string describing the error when the input is invalid.
// The string surfaces in the form UI and blocks "Save & Apply" until cleared.
//
// All functions here are synchronous, dependency-free, and have NO DOM /
// LuCI runtime requirements — they can be unit-tested with plain node.
// See tests/ui/validators.test.ts.

function uuid(v) {
	if (typeof v !== 'string' ||
	    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v))
		return _('Invalid UUID format');
	return true;
}

// url — lenient http(s):// URL shape check for fields like the subscription
// URL (BUG-1). Accepts http:// or https:// followed by at least one non-space
// character. Deliberately permissive: curl is the authoritative parser at fetch
// time, here we only catch the common "forgot the scheme / pasted garbage"
// mistakes so the form blocks Save & Apply with inline feedback. An empty value
// is the caller's concern (rmempty=false handles the required case).
function url(v) {
	if (typeof v !== 'string' || !v.length)
		return _('URL must not be empty');
	if (!/^https?:\/\/\S+$/i.test(v.trim()))
		return _('Must be an http:// or https:// URL');
	return true;
}

// alpn — per spec C2.2.3, an empty ALPN list is valid in sing-box
// (the server picks a default). Only validate the *shape* of each entry:
// every non-blank token must be a known protocol identifier.
function alpn(list) {
	var known = { 'http/1.1': 1, 'h2': 1, 'h3': 1 };
	var arr;
	if (list === null || list === undefined)
		arr = [];
	else if (Array.isArray(list))
		arr = list;
	else if (typeof list === 'string')
		arr = list.split(/[,\s]+/);
	else
		arr = [];
	for (var i = 0; i < arr.length; i++) {
		var s = arr[i];
		if (typeof s !== 'string' || s.length === 0) continue; // blank entries OK
		if (!known[s])
			return _('Unknown ALPN protocol:') + ' ' + s +
			       ' (' + _('expected http/1.1, h2, or h3') + ')';
	}
	return true;
}

return L.Class.extend({
	uuid: uuid,
	url:  url,
	alpn: alpn,
});
