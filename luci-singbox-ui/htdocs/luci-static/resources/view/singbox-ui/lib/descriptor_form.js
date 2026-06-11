'use strict';
'require form';
'require ui';
'require uci';
'require network';
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
    // Dynamic selectors populate their choices at load() time (see
    // attachDynamic). `devices` is a free-entry multi list; every other
    // source is a single-select reference to an existing section.
    if (field.dynamic)
        return (field.dynamic === 'devices') ? form.DynamicList : form.ListValue;
    if (t === 'enum') return form.ListValue;
    if (t === 'list') return form.DynamicList;
    // A string/list field carrying a static `values` array still renders as a
    // free-entry widget (Value / DynamicList); the values become datalist
    // suggestions, not a strict whitelist. Only `enum` is a strict dropdown.
    return form.Value;
}

// Dynamic selectors: options are populated from live UCI / network state at
// .load() time instead of a static `values` array. Generalises the
// loadOutboundList() pattern from tabs/common.js over a `source` discriminator.
function dynamicChoices(source) {
    if (source === 'outbounds')
        return uci.sections('singbox-ui', 'outbound')
            .map(function (s) { return [s['.name'], s['.name']]; })
            .sort(function (a, b) { return a[0] < b[0] ? -1 : (a[0] > b[0] ? 1 : 0); });
    if (source === 'dns_servers')
        return uci.sections('singbox-ui', 'dns_server')
            .map(function (s) { return [s['.name'], s['.name'] + ' (' + (s.type || '?') + ')']; });
    if (source === 'interfaces')
        return uci.sections('network', 'interface')
            .filter(function (s) { return s['.name'] !== 'loopback'; })
            .map(function (s) { return [s['.name'], s['.name']]; });
    return [];
}

function attachDynamic(opt, field) {
    // Device suggestions need the async network runtime and must NOT restrict
    // input: netdev names like eth0.100 / pppoe-wan aren't all enumerable, so
    // they render as free-entry DynamicList datalist hints.
    if (field.dynamic === 'devices') {
        opt.load = function (section_id) {
            var self = this, args = arguments;
            return network.getDevices().then(function (devs) {
                (devs || []).forEach(function (d) {
                    var n = d.getName ? d.getName() : String(d);
                    if (n) self.value(n, n);
                });
                return form.DynamicList.prototype.load.apply(self, args);
            });
        };
        return;
    }
    // Single-select reference to an existing section. Optional fields get a
    // leading (none); required ones don't.
    opt.load = function (section_id) {
        this.keylist = [];
        this.vallist = [];
        if (!field.required) this.value('', _('(none)'));
        var self = this;
        dynamicChoices(field.dynamic).forEach(function (kv) { self.value(kv[0], kv[1]); });
        return form.ListValue.prototype.load.apply(this, arguments);
    };
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
            if (!f.dynamic && Array.isArray(f.values))
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
        if (!f.dynamic && Array.isArray(f.values))
            f.values.forEach(function (v) {
                opt.value(v, v === '' ? _('(none)') : v);
                values[v] = 1;
            });

        if (f.dynamic) attachDynamic(opt, f);

        if (f.secret) {
            opt.password = true;
            decorateSecretInput(opt);
        }

        if (f.virtual) makeVirtual(opt);

        attachValidator(opt, f.validate);
        s._sbMatRegistry[key] = { opt: opt, values: values };
    });
}

return L.Class.extend({
    applyMaterialized: applyMaterialized,
});
