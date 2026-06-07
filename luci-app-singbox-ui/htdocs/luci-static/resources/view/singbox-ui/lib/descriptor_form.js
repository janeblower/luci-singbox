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
	descriptor.fields.forEach(function(f) {
		var group  = f.group || 'advanced';
		var Widget = widgetFor(f);
		var label  = labelFor(f);
		var opt    = s.taboption(group, Widget, f.name, _(label));
		// Inbound uses `protocol` as the discriminator UCI field;
		// outbound uses `type`. The caller's tab must declare a
		// ListValue for whichever name it uses; here we always
		// attach depends to BOTH so the same loop works on either
		// page without the caller having to thread the discriminator.
		opt.depends(kind === 'inbound' ? 'protocol' : 'type', protoName);
		if (f.required)         opt.rmempty  = false;
		if (f.default != null)  opt.default  = String(f.default);
		if (f.type === 'enum' && Array.isArray(f.values)) {
			f.values.forEach(function(v) { opt.value(v, v === '' ? _('(none)') : v); });
		}
		if (f.secret) opt.password = true;
		attachValidator(opt, f.validate);
	});
}

return L.Class.extend({
	applyDescriptor: applyDescriptor,
});
