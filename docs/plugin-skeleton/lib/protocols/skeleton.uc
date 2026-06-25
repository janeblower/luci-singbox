// lib/plugins/skeleton/protocols/skeleton.uc — skeleton outbound descriptor.
//
// This module is required by init.uc and self-registers a new outbound type
// with the core builder via builder.protocols.registry.try_register().
//
// The module path after installation:
//   /usr/share/singbox-ui/lib/plugins/skeleton/protocols/skeleton.uc
// Require name (from init.uc or anywhere):
//   plugins.skeleton.protocols.skeleton
//
// Mirrors the layout of the main app's builder/protocols/ descriptors.
// See builder/protocols/direct.uc for a minimal real-world example.

let reg = require("builder.protocols.registry");

reg.try_register({
	// The type identifier must be unique across core types and all plugins.
	// Use a plugin-prefixed name to avoid collisions.
	type: "skeleton_proto",

	// Human-readable label shown in the outbound type dropdown.
	label: "Skeleton Protocol",

	// Descriptor fields.  See docs/plugins.md and builder/protocols/direct.uc
	// for the full field reference (json_key, coerce, omit_when, requires, etc.).
	fields: [
		// Example field: a server address.
		// {
		//     label:    "Server",
		//     key:      "server",
		//     json_key: "server",
		//     coerce:   "str",
		//     omit_when: "empty",
		// },
	],

	// Optional: emit(s) escape-hatch for types that cannot be built declaratively.
	// emit: function (s) {
	//     let out = {};
	//     // Build the outbound object from UCI section `s`.
	//     return out;
	// },
});

return {};
