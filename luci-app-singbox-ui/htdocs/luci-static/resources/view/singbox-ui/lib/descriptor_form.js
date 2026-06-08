'use strict';
'require form';
'require ui';
'require view.singbox-ui.lib.validators as validators';

// applyDescriptor(s, kind, protoName, descriptor)
//   s          — LuCI section instance (form.GridSection / form.NamedSection)
//   kind       — 'outbound' | 'inbound'
//   protoName  — UCI 'type' / 'protocol' discriminator value
//   descriptor — schema.<kind>.<protoName> from protocol_schema RPC
//
// Side effect: calls s.taboption() for each descriptor field, attaches
// depends('type', protoName), wires validators by symbolic name.

function widgetFor(field) {
	var t = field.type;
	if (t === 'bool')   return form.Flag;
	if (t === 'enum')   return form.ListValue;
	if (t === 'list')   return form.DynamicList;
	return form.Value;  // string, number, anything else default to Value
}

function labelFor(field) {
	if (field.ui_label) return field.ui_label;
	return field.name.charAt(0).toUpperCase() + field.name.slice(1).replace(/_/g, ' ');
}

function attachValidator(opt, validateName) {
	if (!validateName) return;
	var fn = validators[validateName];
	if (typeof fn === 'function') {
		opt.validate = function(_section_id, value) { return fn(value); };
	}
}

function applyDescriptor(s, kind, protoName, descriptor) {
	if (!descriptor || !Array.isArray(descriptor.fields)) return;
	var discr = (kind === 'inbound') ? 'protocol' : 'type';
	s._sbDescriptorRegistry = s._sbDescriptorRegistry || {};
	descriptor.fields.forEach(function(f) {
		var key = f.name;
		var registered = s._sbDescriptorRegistry[key];
		if (registered) {
			// First-descriptor-wins for required/default/secret/validate/widget.
			// Descriptors that share a UCI key (e.g., server, server_port,
			// server_uuid, network) must agree on these attributes; the
			// registry only accumulates depends() and enum values across
			// repeat declarations.
			registered.opt.depends(discr, protoName);
			if (f.type === 'enum' && Array.isArray(f.values))
				f.values.forEach(function(v) {
					if (!registered.values[v]) {
						registered.opt.value(v, v === '' ? _('(none)') : v);
						registered.values[v] = 1;
					}
				});
			return;
		}
		var opt = s.taboption(f.group || 'advanced', widgetFor(f), f.name, _(labelFor(f)));
		opt.modalonly = true;
		opt.depends(discr, protoName);
		if (f.required)        opt.rmempty = false;
		if (f.default != null) opt.default = String(f.default);
		var values = {};
		if (f.type === 'enum' && Array.isArray(f.values))
			f.values.forEach(function(v) {
				opt.value(v, v === '' ? _('(none)') : v);
				values[v] = 1;
			});
		if (f.secret) opt.password = true;
		attachValidator(opt, f.validate);
		s._sbDescriptorRegistry[key] = { opt: opt, values: values };
	});
}

return L.Class.extend({
	applyDescriptor: applyDescriptor,
});
