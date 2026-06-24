// tests/fixtures/plugins/fixture_plugin/init.uc
// Test-only fixture plugin. NOT shipped in any manifest.
// Exercises every framework hook: rpcd method, lifecycle apply/teardown,
// nft fragment, on_generate_post, and descriptor self-registration.

let reg = require("plugins.registry");
let fs = require("fs");

reg.register({
	name: "fixture_plugin", version: "0",
	descriptors: true,
	rpcd: {
		methods: { fixture_ping: function () { printf("%J\n", { status: "ok", pong: true }); } },
		acl_read: ["fixture_ping"], acl_write: [],
	},
	lifecycle: {
		apply: function (cur) { fs.writefile("/tmp/fixture_applied", "1"); },
		teardown: function (cur) { fs.writefile("/tmp/fixture_torndown", "1"); },
	},
	nft: { fragment: function (cur) { return "table inet fixture_marker { }"; } },
	on_generate_post: function (config, ctx) { global._fixture_gen = true; },
});

try { require("plugins.fixture_plugin.descriptor"); } catch (_) {}
return {};
