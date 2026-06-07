// lib/protocols/registry.uc — protocol descriptor registry.
//
// Each protocol module (lib/protocols/<name>.uc) calls register(descriptor)
// at load time. Descriptor shape:
//   { kind: "outbound"|"inbound", type: <UCI type tag>, sing_box_type: <string>,
//     fields: [{ name, type, required?, default?, validate?, secret? }, ...],
//     emit: function(section) -> sing-box JSON object }
//
// The dispatcher in lib/outbound.uc / lib/inbound.uc consults get(kind, type)
// FIRST; if a descriptor is registered, its emit() is called. Otherwise the
// legacy switch-by-type logic runs. This lets us introduce protocols via
// descriptors incrementally without rewriting the existing code.

let _registry = {};

function register(descriptor) {
	assert(descriptor.kind != null, "descriptor.kind required");
	assert(descriptor.type != null, "descriptor.type required");
	assert(type(descriptor.emit) === "function", "descriptor.emit must be a function");
	let key = sprintf("%s:%s", descriptor.kind, descriptor.type);
	_registry[key] = descriptor;
}

function get(kind, type_) {
	return _registry[sprintf("%s:%s", kind, type_)];
}

function types_for_kind(kind) {
	let out = [];
	for (let k in _registry)
		if (_registry[k].kind === kind) push(out, _registry[k].type);
	return out;
}

return { register, get, types_for_kind, _registry };
