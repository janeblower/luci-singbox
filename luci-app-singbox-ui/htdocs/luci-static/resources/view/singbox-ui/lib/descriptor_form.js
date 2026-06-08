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
    opt.write  = function () {};
    opt.remove = function () {};
    var origCfg = opt.cfgvalue;
    opt.cfgvalue = function (section_id) {
        var v = this.formvalue ? this.formvalue(section_id) : null;
        if (v != null) return v;
        return (origCfg ? origCfg.call(this, section_id) : opt.default || '0');
    };
}

function applyMaterialized(s, kind, protoName, materialized) {
    if (!materialized || !Array.isArray(materialized.fields)) return;
    var discr = (kind === 'inbound') ? 'protocol' : 'type';
    s._sbMatRegistry = s._sbMatRegistry || {};

    // Register every tab once. LuCI hides empty tabs automatically.
    (materialized.tabs || ['basic']).forEach(function (tab) {
        if (!s._sbMatRegistry['__tab__' + tab]) {
            if (typeof s.tab === 'function')
                s.tab(tab, TAB_TITLES[tab] || tab);
            s._sbMatRegistry['__tab__' + tab] = 1;
        }
    });

    // Inject a _show_advanced_<tab> virtual bool at the start of each tab
    // that contains advanced fields. The field controls advanced visibility
    // without writing to UCI.
    var advancedTabs = {};
    materialized.fields.forEach(function (f) {
        if (f.advanced && f.tab) advancedTabs[f.tab] = true;
    });
    Object.keys(advancedTabs).forEach(function (tab) {
        var advKey = '__adv__' + tab;
        if (!s._sbMatRegistry[advKey]) {
            var advOpt = s.taboption(tab, form.Flag, '_show_advanced_' + tab, _('Show advanced'));
            advOpt.modalonly = true;
            advOpt.default   = '0';
            makeVirtual(advOpt);
            s._sbMatRegistry[advKey] = { opt: advOpt };
        }
    });

    materialized.fields.forEach(function (f) {
        var key = f.tab + '\t' + f.name;
        var registered = s._sbMatRegistry[key];
        if (registered) {
            // Same shared field appearing for a second protocol: extend the
            // depends() chain so the field shows for that protocol too.
            var deps = {};
            deps[discr] = protoName;
            registered.opt.depends(deps);
            return;
        }
        var opt = s.taboption(f.tab, widgetFor(f), f.name, _(labelFor(f)));
        opt.modalonly = true;

        // Dependency chain: protocol = protoName AND (depends/parent_enabled/advanced).
        // depends.value may be a string (single match) or an array (any-of) —
        // LuCI ORs successive opt.depends() calls together, so emit one per
        // accepted value.
        var values = (f.depends && Array.isArray(f.depends.value))
            ? f.depends.value
            : (f.depends ? [f.depends.value] : [null]);
        values.forEach(function (v) {
            var deps = {};
            deps[discr] = protoName;
            if (f.depends) deps[f.depends.field] = v;
            if (f.parent_enabled) deps[f.parent_enabled] = '1';
            if (f.advanced) deps['_show_advanced_' + f.tab] = '1';
            opt.depends(deps);
        });

        if (f.required)        opt.rmempty = false;
        if (f.default != null) opt.default = String(f.default);
        if (f.placeholder)     opt.placeholder = f.placeholder;

        if (f.type === 'enum' && Array.isArray(f.values))
            f.values.forEach(function (v) {
                opt.value(v, v === '' ? _('(none)') : v);
            });

        if (f.secret) {
            opt.password = true;
            decorateSecretInput(opt);
        }

        if (f.virtual) makeVirtual(opt);

        attachValidator(opt, f.validate);
        s._sbMatRegistry[key] = { opt: opt };
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
