// tests/fixtures/plugins/fixture_plugin/descriptor.uc
// Test-only outbound descriptor. NOT shipped in any manifest.
// Proves descriptor self-registration works through discovery.
// Uses try_register() so a framework validation change never aborts init.uc.
// emit() escape-hatch used because fields:[] would fail the non-empty assertion.

let reg = require("builder.protocols.registry");
reg.try_register({
	kind: "outbound", type: "fixture_proto", sing_box_type: "direct",
	emit: function (s) { return {}; },
});
return {};
