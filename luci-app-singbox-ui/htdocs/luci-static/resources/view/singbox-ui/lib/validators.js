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

function isAlpnNonEmpty(list) {
	var arr;
	if (Array.isArray(list))
		arr = list;
	else if (typeof list === 'string')
		arr = list.split(/[,\s]+/);
	else
		arr = [];
	var nonEmpty = arr.filter(function (s) {
		return typeof s === 'string' && s.length > 0;
	});
	if (!nonEmpty.length)
		return _('ALPN must contain at least one protocol');
	return true;
}

function requiresWsPath(transportType, path) {
	if (transportType !== 'ws')
		return true;
	if (typeof path !== 'string' || !path.length)
		return _('WebSocket transport requires a non-empty path');
	return true;
}

function softWarnCongestion(v) {
	var known = ['cubic', 'new_reno', 'bbr'];
	if (typeof v === 'string' && v.length && known.indexOf(v) < 0) {
		if (typeof console !== 'undefined' && console.warn)
			console.warn('singbox-ui: unknown congestion_control value: ' + v);
	}
	// Always non-blocking — see spec B6 / Phase 8 "warn but allow".
	return true;
}

return L.Class.extend({
	isPort:             isPort,
	isUuid:             isUuid,
	isHost:             isHost,
	isAlpnNonEmpty:     isAlpnNonEmpty,
	requiresWsPath:     requiresWsPath,
	softWarnCongestion: softWarnCongestion,
});
