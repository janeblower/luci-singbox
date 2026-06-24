'use strict';
'require rpc';

// Plugin frontend loader. The backend `plugins` rpcd method lists installed
// plugins; we dynamically L.require() each enabled plugin's frontend module and
// merge its contributions. A plugin module's default export may expose any of:
//   outboundTypes(), inboundTypes(), tabs(), settingsSections(m),
//   renderOutboundForm(type, section, ctx), mode()
// All optional; missing ones are simply skipped.

var callPlugins = rpc.declare({ object: 'singbox-ui', method: 'plugins' });

function loadEnabled() {
	return L.resolveDefault(callPlugins(), null).then(function (r) {
		if (!r || r.status !== 'ok' || !Array.isArray(r.plugins)) return [];
		var enabled = r.plugins.filter(function (p) { return p.enabled; });
		return Promise.all(enabled.map(function (p) {
			return L.require(p.frontend_module).then(function (mod) {
				return { name: p.name, module: p.frontend_module, api: mod || {} };
			}).catch(function (e) {
				// NOTE: use console.error, NOT L.error — in the LuCI runtime L.error()
				// CREATES AND THROWS a tagged exception, which would re-reject this
				// promise and defeat the per-plugin "log + skip" isolation below.
				console.error('plugin frontend load failed: ' + p.frontend_module + ' ' + e);
				return null;
			});
		})).then(function (list) { return list.filter(Boolean); });
	});
}

// --- pure merge helpers (runtime-free; mirrored in tests/ui/_plugins_harness.ts) ---
function collectOutboundTypes(plugins) {
	var out = [];
	plugins.forEach(function (p) { if (p.api && p.api.outboundTypes) out = out.concat(p.api.outboundTypes()); });
	return out;
}
function collectTabs(plugins) {
	var out = [];
	plugins.forEach(function (p) { if (p.api && p.api.tabs) out = out.concat(p.api.tabs()); });
	return out;
}
function collectModes(plugins) {
	var out = [];
	plugins.forEach(function (p) { if (p.api && p.api.mode) { var m = p.api.mode(); if (m) out.push(m); } });
	return out;
}
function applySettingsSections(plugins, m) {
	plugins.forEach(function (p) { if (p.api && p.api.settingsSections) p.api.settingsSections(m); });
}
function formRendererFor(plugins, type) {
	for (var i = 0; i < plugins.length; i++) {
		var p = plugins[i];
		if (p.api && p.api.renderOutboundForm && p.api.outboundTypes) {
			var has = p.api.outboundTypes().some(function (t) { return t[0] === type; });
			if (has) return p.api.renderOutboundForm.bind(p.api);
		}
	}
	return null;
}

return L.Class.extend({
	loadEnabled: loadEnabled,
	collectOutboundTypes: collectOutboundTypes,
	collectTabs: collectTabs,
	collectModes: collectModes,
	applySettingsSections: applySettingsSections,
	formRendererFor: formRendererFor,
});
