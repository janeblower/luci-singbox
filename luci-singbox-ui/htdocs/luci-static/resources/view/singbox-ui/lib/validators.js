'use strict';

// Pure-function validators for LuCI form .validate callbacks.
//
// Contract reminder (LuCI form): a .validate callback returns
//   - true (or any truthy non-string) when the input is valid;
//   - a non-empty string describing the error when the input is invalid.
// The string surfaces in the form UI and blocks "Save & Apply" until cleared.
//
// All functions here are synchronous, dependency-free, and have NO DOM /
// LuCI runtime requirements — they can be unit-tested with plain node.
// See tests/test_validators_js.sh.

function isPort(v) {
	// Accept either a numeric or a string that parses cleanly to an integer.
	var n;
	if (typeof v === 'number') {
		n = v;
	} else if (typeof v === 'string' && /^-?\d+$/.test(v.trim())) {
		n = parseInt(v.trim(), 10);
	} else {
		return _('Port must be an integer between 1 and 65535');
	}
	if (!isFinite(n) || n < 1 || n > 65535)
		return _('Port must be an integer between 1 and 65535');
	return true;
}

function isUuid(v) {
	if (typeof v !== 'string' ||
	    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v))
		return _('Invalid UUID format');
	return true;
}

function isHost(v) {
	if (typeof v !== 'string' || !v.length)
		return _('Host must not be empty');

	// IPv4 dotted-quad, 0-255 per octet.
	var ipv4 = /^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/;
	// IPv6: lenient — any non-empty string composed of hex digits / colons
	// that contains at least one colon. LuCI's own ipaddr datatype validates
	// rigorously at form-render time; here we just need to recognise the
	// shape to permit the field to pass our custom validator alongside.
	var ipv6 = /^[0-9a-fA-F:]+$/;
	// RFC 1035 lenient hostname: 1-253 chars total; each label 1-63 chars,
	// alphanumeric + hyphen, must not start/end with hyphen.
	var domain = /^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$/;

	if (ipv4.test(v))
		return true;
	if (v.indexOf(':') >= 0 && ipv6.test(v))
		return true;
	if (domain.test(v))
		return true;
	return _('Must be a valid IPv4 address, IPv6 address, or hostname');
}

// validateAlpn — per spec C2.2.3, an empty ALPN list is valid in sing-box
// (the server picks a default). Only validate the *shape* of each entry:
// every non-blank token must be a known protocol identifier.
function validateAlpn(list) {
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

function requiresWsPath(transportType, path) {
	if (transportType !== 'ws')
		return true;
	if (typeof path !== 'string' || !path.length)
		return _('WebSocket transport requires a non-empty path');
	return true;
}

// softWarnCongestion — PURE, non-blocking validator (spec S2-8). It only
// *classifies* the value; it must not touch L/E/console (the module contract
// at the top of this file). An unknown value is permitted (sing-box rejects it
// at runtime if truly invalid); callers that want a UI hint can compare against
// KNOWN_CONGESTION themselves.
var KNOWN_CONGESTION = ['cubic', 'new_reno', 'bbr', 'brutal'];
function isKnownCongestion(v) {
	return !(typeof v === 'string' && v.length && KNOWN_CONGESTION.indexOf(v) < 0);
}
function softWarnCongestion(v) {
	// Non-blocking by design — always valid. Classification lives in
	// isKnownCongestion for callers that want to surface a warning.
	void isKnownCongestion(v);
	return true;
}

return L.Class.extend({
	isPort:              isPort,
	isUuid:              isUuid,
	isHost:              isHost,
	validateAlpn:        validateAlpn,
	requiresWsPath:      requiresWsPath,
	softWarnCongestion:  softWarnCongestion,
	isKnownCongestion:   isKnownCongestion,
});
