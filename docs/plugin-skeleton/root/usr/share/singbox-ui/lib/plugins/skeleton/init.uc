// Skeleton plugin for luci-app-singbox-ui (Phase E).
//
// COPY THIS DIRECTORY and rename every occurrence of "skeleton" to your plugin
// name.  Plugin names must be underscore-only (letters, digits, underscores).
// Dashes break ucode's require() module resolution.
//
// Only the hooks you actually implement need to be present in register().
// The only required field is `name`.

let reg = require("plugins.registry");

reg.register({
	// -------------------------------------------------------------------------
	// Identity — required.
	// -------------------------------------------------------------------------
	name:    "skeleton",
	version: "1",

	// -------------------------------------------------------------------------
	// Descriptor self-registration — optional.
	//
	// Set `descriptors: true` when your init.uc require()s modules that call
	// builder.protocols.registry.try_register() to add new outbound/inbound
	// types to the core builder.  This field is purely documentary (the
	// framework does not read it); it signals intent to readers.
	// -------------------------------------------------------------------------
	// descriptors: true,
	// try { require("plugins.skeleton.descriptor"); } catch (_) {}

	// -------------------------------------------------------------------------
	// rpcd methods — optional.
	//
	// Each function is called by the rpcd dispatcher when a matching ubus call
	// arrives.  Read arguments via parse_args() (reads stdin JSON); write the
	// result via printf("%J\n", ...).  There is no wrapper object — the
	// function is invoked directly.
	//
	// Declare the same method names in your own acl.d JSON (see
	// root/usr/share/rpcd/acl.d/luci-singbox-plugin-skeleton.json).
	// The ACL-sync guard unions all acl.d files, so your file is checked
	// automatically when the plugin is installed alongside the core package.
	//
	// Method name collisions with core methods: the core method wins and a
	// warning is logged.  Use a plugin-specific prefix to avoid collisions.
	// -------------------------------------------------------------------------
	rpcd: {
		methods: {
			skeleton_hello: function () {
				printf("%J\n", { status: "ok", message: "hello from skeleton" });
			},
		},
		acl_read:  ["skeleton_hello"],
		acl_write: [],
	},

	// -------------------------------------------------------------------------
	// Lifecycle hooks — optional.
	//
	// Called by apply-plugins.uc under the lifecycle-lock (same serialization
	// that wraps init.d start/stop/restart).  Both functions receive a
	// uci.cursor() instance.  They must be idempotent — they may be called
	// multiple times.  Errors are logged and the next plugin's hooks still run.
	// -------------------------------------------------------------------------
	lifecycle: {
		apply: function (cur) {
			// Reconcile resources from UCI.  Example: write a config file,
			// register a service, set a sysctl.
		},
		teardown: function (cur) {
			// Remove resources created by apply.  Example: delete the config
			// file, de-register the service.
		},
	},

	// -------------------------------------------------------------------------
	// nftables fragment — optional.
	//
	// Return a complete `table <family> <name> { ... }` string.  The fragment
	// is appended verbatim to the core singbox_ui nft ruleset and applied
	// atomically via `nft -f`.  Return "" or null to contribute nothing.
	//
	// The fragment is included even when no transparent inbound is active, so
	// a plugin may add masquerade or other rules independently of the core
	// tproxy table.
	//
	// cur is a uci.cursor() instance.
	// -------------------------------------------------------------------------
	nft: {
		fragment: function (cur) {
			// Example: return "table inet skeleton_table { }";
			return "";
		},
	},

	// -------------------------------------------------------------------------
	// Config post-processing hook — optional.
	//
	// Called once per generate.uc run, after the core builders finish but
	// before the JSON is written to /tmp/singbox-ui.json.  Mutate `config`
	// in place.
	//
	// config: the complete sing-box config object
	//   { log, dns, inbounds, outbounds, route, experimental, ... }
	// ctx: { implicit_tags: [...], generation_ts: <number>, ... }
	//   (additive — new fields may be added without breaking plugins)
	//
	// MUST NOT throw.  Exceptions are caught, logged via log_event, and the
	// rest of the plugin chain still runs.
	//
	// Invariants:
	//   - Do not delete `route` or `outbounds` (sing-box rejects configs
	//     missing these keys).
	//   - Use a unique tag prefix (e.g. "skeleton-") for any outbound you
	//     inject to avoid duplicate-tag errors.
	//   - Do not call back into LuCI/RPC (runs synchronously inside rpcd).
	// -------------------------------------------------------------------------
	on_generate_post: function (config, ctx) {
		// Example: inject an extra outbound.
		// push(config.outbounds, { type: "direct", tag: "skeleton-direct" });
	},
});

return {};
