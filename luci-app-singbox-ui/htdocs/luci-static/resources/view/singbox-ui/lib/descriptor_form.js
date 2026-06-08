'use strict';
'require form';
'require ui';
'require view.singbox-ui.lib.validators as validators';

// Phase E2: applyMaterialized(s, kind, protoName, materialized)
//   materialized comes from the protocol_schema RPC after registry.materialize().
//   Shape: { sing_box_type, tabs:[...], shared:{...}, fields:[...] }
//   Each field has: name, type, tab, required?, default?, validate?, secret?,
//                   advanced?, depends?:{field,value}, parent_enabled?,
//                   placeholder?, values?, virtual?
//
// Renders LuCI tab options with per-tab Advanced toggle, parent_enabled
// dependency wiring, conditional visibility (depends), pre-populated
// defaults and the standard secret-input eye toggle.

var TAB_TITLES = {
    basic:     _('Basic'),
    tls:       _('TLS'),
    transport: _('Transport'),
    multiplex: _('Multiplex'),
    dial:      _('Dial'),
};

function widgetFor(field) {
    var t = field.type;
    if (t === 'bool') return form.Flag;
    if (t === 'enum') return form.ListValue;
    if (t === 'list') return form.DynamicList;
    return form.Value;
}

function labelFor(field) {
    if (field.ui_label) return field.ui_label;
    return field.name.charAt(0).toUpperCase() + field.name.slice(1).replace(/_/g, ' ');
}

function attachValidator(opt, validateName) {
    if (!validateName) return;
    var fn = validators[validateName];
    if (typeof fn === 'function')
        opt.validate = function (_section_id, value) { return fn(value); };
}

function decorateSecretInput(opt) {
    var orig = opt.renderWidget;
    opt.renderWidget = function (section_id, option_index, cfgvalue) {
        var node = orig.call(this, section_id, option_index, cfgvalue);
        var input = (node.tagName === 'INPUT') ? node
            : (node.querySelector && node.querySelector('input[type="password"]'));
        if (!input) return node;
        var btn = E('button', {
            'type': 'button',
            'class': 'cbi-button sb-eye-toggle',
            'aria-label': _('Toggle visibility'),
            'click': function (ev) {
                ev.preventDefault();
                var shown = (input.type === 'text');
                input.type = shown ? 'password' : 'text';
                btn.textContent = shown ? _('Show') : _('Hide');
            }
        }, _('Show'));
        return E('span', { 'class': 'sb-secret-wrap' }, [node, btn]);
    };
}

function makeVirtual(opt) {
    // Virtual fields exist only in the form DOM; never written to UCI.
    // cfgvalue must NOT call formvalue — formvalue dereferences the
    // rendered UI element which doesn't exist during pre-render cfgvalue
    // (`findElements` throws TypeError on undefined node). LuCI's depends()
    // machinery reads the current value via formvalue at runtime, so we
    // only need cfgvalue to return the initial (default) state.
    opt.write  = function () {};
    opt.remove = function () {};
    var defVal = (opt.default != null) ? String(opt.default) : '0';
    opt.cfgvalue = function () { return defVal; };
}

function applyMaterialized(s, kind, protoName, materialized) {
    if (!materialized || !Array.isArray(materialized.fields)) return;
    var discr = (kind === 'inbound') ? 'protocol' : 'type';
    s._sbMatRegistry = s._sbMatRegistry || {};

    // Register every tab once across the whole section lifetime. LuCI's
    // s.tab() throws "Tab already declared" if the section already has the
    // tab — that includes manual registrations in the caller (tabs/*.js
    // declare the standard set up front). Probe s.tabs (LuCI internal) and
    // skip when present.
    (materialized.tabs || ['basic']).forEach(function (tab) {
        if (s._sbMatRegistry['__tab__' + tab]) return;
        var alreadyDeclared = Array.isArray(s.tabs)
            && s.tabs.some(function (t) { return t && t.name === tab; });
        if (!alreadyDeclared && typeof s.tab === 'function')
            s.tab(tab, TAB_TITLES[tab] || tab);
        s._sbMatRegistry['__tab__' + tab] = 1;
    });

    // _show_advanced_<tab> virtual fields are pre-injected by
    // registry.materialize() into materialized.fields with virtual:true and
    // ui_label "Show advanced fields". The main field loop below registers
    // them with makeVirtual once per (tab,name) pair — no separate pass
    // required.

    // Build the full depends arms for a (field, protoName) pair: protocol
    // gate AND every (parent_enabled / advanced / per-value depends) clause.
    // The same field can be declared by multiple protocols — each call must
    // produce its own arm so the OR semantics of opt.depends() correctly
    // gate by the right protocol AND the right advanced/parent state.
    function depsArmsFor(f, protoName) {
        var values = (f.depends && Array.isArray(f.depends.value))
            ? f.depends.value
            : (f.depends ? [f.depends.value] : [null]);
        return values.map(function (v) {
            var d = {};
            d[discr] = protoName;
            if (f.depends) d[f.depends.field] = v;
            if (f.parent_enabled) d[f.parent_enabled] = '1';
            if (f.advanced) d['_show_advanced_' + f.tab] = '1';
            return d;
        });
    }

    materialized.fields.forEach(function (f) {
        var key = f.tab + '\t' + f.name;
        var registered = s._sbMatRegistry[key];
        if (registered) {
            // Same shared field appearing for another protocol: extend the
            // depends() chain with the new protocol's full gate (NOT just
            // discr=proto — that would bypass advanced/parent_enabled and
            // make the field unconditionally visible for the new protocol).
            depsArmsFor(f, protoName).forEach(function (d) {
                registered.opt.depends(d);
            });
            if (f.type === 'enum' && Array.isArray(f.values))
                f.values.forEach(function (v) {
                    if (!registered.values[v]) {
                        registered.opt.value(v, v === '' ? _('(none)') : v);
                        registered.values[v] = 1;
                    }
                });
            return;
        }
        var opt = s.taboption(f.tab, widgetFor(f), f.name, _(labelFor(f)));
        opt.modalonly = true;

        depsArmsFor(f, protoName).forEach(function (d) { opt.depends(d); });

        if (f.required)        opt.rmempty = false;
        if (f.default != null) opt.default = String(f.default);
        if (f.placeholder)     opt.placeholder = f.placeholder;

        var values = {};
        if (f.type === 'enum' && Array.isArray(f.values))
            f.values.forEach(function (v) {
                opt.value(v, v === '' ? _('(none)') : v);
                values[v] = 1;
            });

        if (f.secret) {
            opt.password = true;
            decorateSecretInput(opt);
        }

        if (f.virtual) makeVirtual(opt);

        attachValidator(opt, f.validate);
        s._sbMatRegistry[key] = { opt: opt, values: values };
    });
}

// ---------------------------------------------------------------------------
// applyDescriptor — legacy E1 renderer (kept for T17 migration window).
//   Uses the old descriptor format: fields have `group` instead of `tab`,
//   and depends is a flat depends(key, val) call rather than an object chain.
//   T17 will update inbounds.js and outbounds.js to call applyMaterialized
//   directly, after which this function can be removed.
// ---------------------------------------------------------------------------
function applyDescriptor(s, kind, protoName, descriptor) {
    if (!descriptor || !Array.isArray(descriptor.fields)) return;
    var discr = (kind === 'inbound') ? 'protocol' : 'type';
    s._sbDescriptorRegistry = s._sbDescriptorRegistry || {};
    descriptor.fields.forEach(function(f) {
        var key = f.name;
        var registered = s._sbDescriptorRegistry[key];
        if (registered) {
            // First-descriptor-wins for required/default/secret/validate/widget.
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
        if (f.secret) {
            opt.password = true;
            decorateSecretInput(opt);
        }
        attachValidator(opt, f.validate);
        s._sbDescriptorRegistry[key] = { opt: opt, values: values };
    });
}

return L.Class.extend({
    applyMaterialized: applyMaterialized,
    applyDescriptor:   applyDescriptor,
});
