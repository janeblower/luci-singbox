'use strict';
'require form';
'require ui';
'require uci';
'require network';
'require view.singbox-ui.lib.validators as validators';
'require view.singbox-ui.lib.view_state as SbViewState';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.rpc as SbRpc';

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
    match:     _('Match'),
    action:    _('Action'),
    tls:       _('TLS'),
    transport: _('Transport'),
    multiplex: _('Multiplex'),
    dial:      _('Dial'),
    listen:    _('Listen'),
};

function widgetFor(field) {
    var t = field.type;
    if (t === 'bool') return form.Flag;
    // A LIST WITH CHOICES is a checkbox dropdown (MultiValue) — the very widget
    // the LuCI firewall uses for "Covered networks". It stays OPEN across clicks;
    // a DynamicList made you reopen the dropdown for every single item.
    //
    // In the container's form.js (verified there, not against master — the two
    // differ) CBIMultiValue *extends* CBIDynamicList and only overrides
    // renderWidget with `new ui.Dropdown(..., {multiple:true, create:this.create})`.
    // load/parse/write and the UCI list format are therefore identical: the swap
    // is drop-in at the model level, only the widget changes.
    //
    // A list with NO choices (free-form CIDRs — tun.address, route_address,
    // loopback_address; user lists) stays a DynamicList: there is nothing to
    // drop down.
    if (t === 'list')
        return (field.dynamic || Array.isArray(field.values)) ? form.MultiValue
                                                              : form.DynamicList;
    // Dynamic selectors populate their choices at load() time (see
    // attachDynamic). The source decides WHERE the choices come from; the
    // field's own `type` decides the widget.
    //
    // `devices` used to force a DynamicList regardless of type, which rendered
    // every SCALAR netdev field (dns/dhcp.uc `interface`, dial.uc
    // `bind_interface`) as a multi-value list. Netdev names aren't fully
    // enumerable (eth0.100, pppoe-wan), so a scalar one is a free-entry Value —
    // LuCI turns a Value with choices into a Combobox: suggestions, not a
    // whitelist. Section references stay strict single-selects.
    if (field.dynamic) {
        if (field.dynamic === 'devices') return form.Value;
        return form.ListValue;
    }
    if (t === 'enum') return form.ListValue;
    // Multiline string fields render as a textarea widget (TextValue) instead of
    // a single-line input. Used for PEM keys, raw JSON, and share-link URLs.
    if (t === 'string' && field.multiline) return form.TextValue;
    // A string field carrying a static `values` array still renders as a
    // free-entry Value; the values become datalist suggestions, not a strict
    // whitelist. Only `enum` is a strict dropdown.
    return form.Value;
}

// Map a LuCI CBI widget constructor to a stable, lowercase control kind for the
// data-sb-control hook. Identity comparison works both against real LuCI classes
// and the unit-test string stub. form.Value (single-line input) is the default.
// MultiValue is probed BEFORE DynamicList: it extends it, and an identity check
// must not be allowed to fall through to the wrong kind.
function controlKindFor(widget) {
    if (widget === form.Flag)        return 'checkbox';
    if (widget === form.ListValue)   return 'list';
    if (widget === form.MultiValue)  return 'multi';
    if (widget === form.DynamicList) return 'dynamic';
    if (widget === form.TextValue)   return 'textarea';
    return 'text';
}

// Stamp a stable, i18n-independent test hook onto a field's widget node so the
// e2e/matrix suites can select it by descriptor name instead of label text.
// Mirrors the renderWidget-wrap idiom of disableWithNote/makeExclusive: guarded,
// sync node return. The marker props are set unconditionally so materialize-level
// unit tests can assert hook coverage without a DOM.
function tagField(opt, name, control) {
    opt._sbField = name;
    if (control) opt._sbControl = control;
    var orig = opt.renderWidget;
    if (typeof orig === 'function') {
        opt.renderWidget = function (section_id, option_index, cfgvalue) {
            var node = orig.call(this, section_id, option_index, cfgvalue);
            if (node && typeof node.setAttribute === 'function') {
                node.setAttribute('data-sb-field', name);
                if (control) node.setAttribute('data-sb-control', control);
            }
            return node;
        };
    }
}

// Frontend mirror of helpers.ruleset_active() — the backend's ONE predicate for
// "is this rule-set live". It honours the built-in master switch
// (main.default_rulesets, unset = ON) on top of the section's own `enabled`, and
// route.uc / dns.uc / nft-rulesets.uc all PRUNE anything it rejects.
//
// The picker must offer nothing the backend then throws away: a reference to a
// pruned rule-set is dropped with a warn the user never sees. For
// tun.route_address_set that silent prune INVERTS the tunnel — the field means
// "ONLY these CIDRs enter the tun", so losing it makes the tun capture the whole
// address space.
function rulesetActive(s) {
    if (s.enabled === '0') return false;
    if (s.builtin === '1' && uci.get('singbox-ui', 'main', 'default_rulesets') === '0') return false;
    return true;
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
    if (source === 'rulesets')
        return uci.sections('singbox-ui', 'ruleset')
            .filter(rulesetActive)
            .map(function (s) { return [s['.name'], s['.name'] + ' (' + (s.type || '?') + ')']; });
    if (source === 'route_rules')
        return uci.sections('singbox-ui', 'route_rule')
            .filter(function (s) { return (s.type || 'default') === 'default'; })
            .map(function (s) { return [s['.name'], s['.name']]; });
    if (source === 'dns_rules')
        return uci.sections('singbox-ui', 'dns_rule')
            .filter(function (s) { return (s.type || 'default') === 'default'; })
            .map(function (s) { return [s['.name'], s['.name']]; });
    return [];
}

function attachDynamic(opt, field) {
    // The widget is whatever the field's TYPE asked for (MultiValue for a list
    // with choices, Combobox for a scalar netdev, ListValue for a scalar section
    // reference) — hence the prototype is taken from widgetFor(), not hardcoded.
    var Widget = widgetFor(field);

    // Device suggestions need the async network runtime and must NOT restrict
    // input: netdev names like eth0.100 / pppoe-wan aren't all enumerable. This
    // branch serves BOTH the scalar case (dial.bind_interface, dns/dhcp
    // interface) and the list case (tproxy.interface, tun.include_interface).
    if (field.dynamic === 'devices') {
        opt.load = function (section_id) {
            var self = this, args = arguments;
            // Reset first — LuCI calls load() once per render, and opt.value()
            // APPENDS to keylist/vallist. Without this the choices accumulate:
            // eth0 four times over four renders. Harmless-looking in a datalist
            // of suggestions, but a checkbox dropdown shows every duplicate as
            // its own row. Both other branches below already do this.
            this.keylist = [];
            this.vallist = [];
            return network.getDevices().then(function (devs) {
                (devs || []).forEach(function (d) {
                    var n = d.getName ? d.getName() : String(d);
                    if (n) self.value(n, n);
                });
                return Widget.prototype.load.apply(self, args);
            });
        };
        return;
    }
    // Generic multi-select for any list-typed dynamic source (outbounds,
    // rulesets, route_rules). Suggestions come from existing sections; free text
    // stays available through the dropdown's "-- custom --" row (opt.create, set
    // by the caller). Excludes the current section.
    if (field.type === 'list') {
        opt.load = function (section_id) {
            this.keylist = [];
            this.vallist = [];
            var self = this;
            dynamicChoices(field.dynamic).forEach(function (kv) {
                if (kv[0] !== section_id) self.value(kv[0], kv[1]);
            });
            return Widget.prototype.load.apply(this, arguments);
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

// Two-sided version gate. Returns {mode:'show'} | {mode:'disable', note} | {mode:'hide'}.
// Fail-open: unknown core version never gates.
function versionGate(f) {
    var core = (SbViewState.getCoreVersion && SbViewState.getCoreVersion()) || '';
    if (!core) return { mode: 'show' };
    var out = null;
    if (f.min_version && SbCommon.compareVersions(core, f.min_version) < 0) {
        var lo = f.min_version.split('.').slice(0, 2).join('.');
        out = _('requires') + ' ' + lo + '+';
    } else if (f.max_version && SbCommon.compareVersions(core, f.max_version) >= 0) {
        var hi = f.max_version.split('.').slice(0, 2).join('.');
        out = _('removed in') + ' ' + hi;
    }
    if (!out) return { mode: 'show' };
    var compatOnly = SbViewState.getCompatOnly && SbViewState.getCompatOnly();
    return compatOnly ? { mode: 'hide' } : { mode: 'disable', note: '(' + out + ')' };
}

// Disable an option's widget (read-only) and append a note to its title.
function disableWithNote(opt, note) {
    var t = opt.title || '';
    if (t.indexOf(note) < 0) opt.title = t + (t ? ' ' : '') + note;
    opt.readonly = true;
    var orig = opt.renderWidget;
    if (typeof orig === 'function') {
        opt.renderWidget = function (section_id, option_index, cfgvalue) {
            var node = orig.call(this, section_id, option_index, cfgvalue);
            if (node && node.querySelectorAll) {
                node.querySelectorAll('input, select, textarea').forEach(function (el) { el.disabled = true; });
                node.querySelectorAll('.sb-eye-toggle').forEach(function (el) { el.disabled = true; });
            }
            return node;
        };
    }
}

// `requires_pkg`: the field only works if an optional system package is present
// (kTLS needs kmod-tls). Probe once per page — rpcd forks apk per call — and,
// when it is missing, append an inline note carrying a one-click install button.
// Fail-open: an unanswered probe leaves the note without a button rather than
// nagging the user to install something that may already be there.
var pkgProbe = {};
function pkgInstalled(pkg) {
    if (!pkgProbe[pkg])
        pkgProbe[pkg] = SbRpc.callPkgStatus(pkg)
            .then(function (r) { return !!(r && r.installed); })
            .catch(function () { return true; });
    return pkgProbe[pkg];
}

function attachPkgNote(opt, pkg) {
    var orig = opt.renderWidget;
    if (typeof orig !== 'function') return;
    opt.renderWidget = function (section_id, option_index, cfgvalue) {
        var node = orig.call(this, section_id, option_index, cfgvalue);
        if (!node || typeof node.appendChild !== 'function') return node;
        var note = E('div', { 'class': 'cbi-value-description' },
                     _('Requires the %s package.').format(pkg) + ' ');
        node.appendChild(note);
        pkgInstalled(pkg).then(function (installed) {
            if (installed) return;
            var btn = E('button', {
                'type': 'button',
                'class': 'cbi-button cbi-button-action',
                'click': function (ev) {
                    ev.preventDefault();
                    btn.disabled = true;
                    btn.textContent = _('Installing…');
                    SbRpc.callPkgInstall(pkg).then(function (r) {
                        if (r && r.status === 'ok') {
                            pkgProbe[pkg] = Promise.resolve(true);
                            btn.parentNode.removeChild(btn);
                            note.appendChild(document.createTextNode(_('Installed.')));
                            return;
                        }
                        btn.disabled = false;
                        btn.textContent = _('Install');
                        ui.addNotification(null,
                            E('p', _('Failed to install %s').format(pkg)), 'error');
                    });
                }
            }, _('Install'));
            note.appendChild(btn);
        });
        return node;
    };
}

// LuCI's own validation.js already ships these as datatypes; a descriptor that
// says validate:"port" gets LuCI's port check, not a hand-rolled one. The rest
// (uuid, alpn) have no LuCI equivalent and stay in lib/validators.js, whose
// export names now match the descriptor strings — so no name mangling.
//
// port is composed as and(port,min(1)): LuCI's bare 'port' datatype accepts
// 0 (validation.js: `p >= 0 && p <= 65535`), but 0 is not a usable
// listen_port/server_port — lib/builder/_shared/dial.uc treats a falsy port
// as "absent" and silently drops the whole inbound. min(1) restores the
// 1..65535 contract the old hand-rolled isPort enforced.
var DATATYPE = { port: 'and(port,min(1))', host: 'host' };

function attachValidator(opt, name) {
    if (typeof name !== 'string' || !name) return;
    if (DATATYPE[name]) { opt.datatype = DATATYPE[name]; return; }
    var fn = validators[name];
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

// Session-scoped (not UCI-backed) store for virtual toggle state, so the
// "Show advanced fields" checkbox survives a modal re-open within the same
// page session instead of always re-initialising to its default (audit 8.3).
// Keyed by section_id + option name; lives only for the page lifetime and is
// never persisted to UCI — keeping the keep-out-of-UCI invariant intact.
var virtualToggleState = {};
function virtualKey(sectionId, optName) { return String(sectionId) + '\0' + String(optName); }

function makeVirtual(opt) {
    // Virtual fields exist only in the form DOM; never written to UCI.
    // cfgvalue must NOT call formvalue — formvalue dereferences the
    // rendered UI element which doesn't exist during pre-render cfgvalue
    // (`findElements` throws TypeError on undefined node). LuCI's depends()
    // machinery reads the current value via formvalue at runtime, so we
    // only need cfgvalue to return the initial state.
    var defVal = (opt.default != null) ? String(opt.default) : '0';
    // write/remove stay no-ops w.r.t. UCI — the toggle must never leak into the
    // generated config. We only mirror the live value into the session store on
    // save so a subsequent modal open restores the user's choice (audit 8.3).
    opt.write  = function (sectionId, value) {
        virtualToggleState[virtualKey(sectionId, this.option)] =
            (value != null) ? String(value) : defVal;
    };
    opt.remove = function (sectionId) {
        delete virtualToggleState[virtualKey(sectionId, this.option)];
    };
    opt.cfgvalue = function (sectionId) {
        var k = virtualKey(sectionId, this.option);
        return (k in virtualToggleState) ? virtualToggleState[k] : defVal;
    };
}

// --- Exclusive flags: "exactly one section may own this" --------------------
//
// Two contracts:
//   exclusive: true        legacy — only one enabled section OF THE SAME PROTOCOL
//                          may set this flag (a second tproxy inbound must not
//                          also own the nft table: one mark, one ip rule).
//   exclusive: "<group>"   cross-protocol — only one enabled section may set ANY
//                          field tagged with <group>, whatever its protocol and
//                          whatever the field is NAMED. Group "transparent" is
//                          system routing / the firewall: tproxy.nft_rules claims
//                          it with our own `inet singbox_ui` table + an ip rule,
//                          tun.auto_route claims it with sing-box's own policy
//                          routing (and auto_redirect's own nft rules). Exactly
//                          one may own it. Mirrors helpers.transparent_claims;
//                          generate.uc refuses to build on a conflict (rc 3) —
//                          this widget is convenience, not enforcement.
//
// THE POLARITY IS PER FIELD, and it is not a style choice. LuCI's
// CBIAbstractValue.parse() REMOVES an option whose submitted value equals its
// `default` (rmempty is true unless the field is `required`), so a flag that
// defaults to ON is ABSENT from UCI while it is on. Hence the one rule that
// covers both fields: an unset flag means whatever its descriptor `default`
// says. That is `!== "0"` for tproxy.nft_rules (default 1, no json_key — nothing
// emits it) and `=== "1"` for tun.auto_route (default 0 on purpose, commit
// 61534499: only an explicit "1" survives parse() and gets emitted). Reading an
// unset auto_route as ON would let a tun that routes NOTHING seize the group and
// kill tproxy's nft rules — no interception at all, silently, and every test
// green. Do not "simplify" this back to a blanket `!== "0"`.
function claimOf(field) {
    return {
        name: field.name,
        def:  String(field.default != null ? field.default : 0),
    };
}

function flagIsOn(sec, claim) {
    var v = sec[claim.name];
    if (v == null || v === '') v = claim.def;   // unset ⇒ the descriptor's default
    return String(v) !== '0';
}

function discrOf(kind) { return (kind === 'inbound') ? 'protocol' : 'type'; }

// { <protocol>: claim } for one exclusive group, read straight off the schema
// the forms are built from (SbViewState). The schema is loaded once, before any
// section renders, so this map is complete regardless of the order in which the
// per-protocol applyMaterialized() calls ran — and main.js can ask the same
// question at Apply time without owning a section object.
function claimsForGroup(kind, group) {
    var protos = (SbViewState.getSchema() || {})[kind] || {};
    var claims = {};
    Object.keys(protos).forEach(function (proto) {
        ((protos[proto] || {}).fields || []).forEach(function (f) {
            if (f.exclusive === group) claims[proto] = claimOf(f);
        });
    });
    return claims;
}

// Enabled sections of `kind` that actually claim, in UCI order. `claims` is
// keyed by protocol, so a protocol absent from it never claims.
function claimants(kind, claims) {
    var discr = discrOf(kind);
    return uci.sections('singbox-ui', kind).filter(function (sec) {
        if (sec.enabled === '0') return false;
        var c = claims[sec[discr]];
        return !!c && flagIsOn(sec, c);
    });
}

// Groups of `kind` claimed by MORE THAN ONE enabled section. The form keeps this
// unreachable (the loser's checkbox is dead), but UCI can be hand-edited, and
// re-enabling a section from the grid can resurrect a rival claim without its
// checkbox ever rendering. main.js blocks Apply on it and names the culprits —
// otherwise generate.uc's refusal (rc 3) reaches the operator as a bare
// "service restart failed", which tells them nothing.
//
// ONE claimant PER PROTOCOL, mirroring helpers.transparent_claims (`!c.tproxy` /
// `!c.tun`): the backend keeps only the FIRST claimant of each protocol, so two
// enabled tproxy inbounds are NOT a conflict to it — it picks the first and the
// config builds. Counting every claimant here would block the whole page's Apply
// on a config the backend accepts, and the second tproxy's `nft_rules` is already
// dead in its modal (makeExclusive), so there is nothing for the operator to turn
// off. A conflict is only ever ACROSS protocols.
function exclusiveConflicts(kind) {
    var protos = (SbViewState.getSchema() || {})[kind] || {};
    var groups = {};
    Object.keys(protos).forEach(function (p) {
        ((protos[p] || {}).fields || []).forEach(function (f) {
            if (typeof f.exclusive === 'string') groups[f.exclusive] = 1;
        });
    });
    var discr = discrOf(kind);
    return Object.keys(groups).map(function (g) {
        var claims = claimsForGroup(kind, g), seen = {};
        return {
            group: g,
            claimants: claimants(kind, claims).filter(function (sec) {
                var p = sec[discr];
                if (seen[p]) return false;
                seen[p] = 1;
                return true;
            }).map(function (sec) {
                return { section: sec['.name'], field: claims[sec[discr]].name };
            }),
        };
    }).filter(function (c) { return c.claimants.length > 1; });
}

// Notify the operator about every conflict, naming BOTH inbounds and the field
// each one claims with — the fix is "turn one of them off", and neither the
// init.d refusal nor LuCI's "service restart failed" says which two to look at.
// Returns true when at least one conflict was found (main.js then holds Apply
// back: the config would not build anyway, and the changes stay staged).
//
// A COURTESY, NOT A GATE. main.js hooks only the VIEW's handleSaveApply; LuCI's
// global "Unsaved changes" indicator calls ui.changes.apply() directly and never
// comes through here. generate.uc's rc-3 refusal is the enforcement. This exists
// so the operator learns WHICH two inbounds to look at instead of reading a bare
// "service restart failed".
function warnExclusiveConflicts(kind) {
    var conflicts = exclusiveConflicts(kind);
    conflicts.forEach(function (c) {
        var who = c.claimants.map(function (x) {
            return '"' + x.section + '" (' + x.field + ')';
        }).join(', ');
        // Array child ⇒ text node (section names are user-controlled).
        ui.addNotification(null, E('p', {}, [
            _('Not applied: inbounds %s both claim system routing / the firewall. Exactly one may own it — turn one of them off, then apply again.').format(who)
        ]), 'error');
    });
    return conflicts.length > 0;
}

// The first claimant owns it; every other section's flag is forced off +
// disabled in the UI (with a comment naming the owner) and can never persist "1".
// A section never blocks itself.
function makeExclusive(opt, field, kind) {
    var group = (typeof field.exclusive === 'string') ? field.exclusive : null;
    var discr = discrOf(kind);

    function ownerOf(section_id) {
        var claims;
        if (group) {
            claims = claimsForGroup(kind, group);
        } else {
            // Legacy contract: only sections of MY protocol claim, via MY field.
            claims = {};
            claims[uci.get('singbox-ui', section_id, discr)] = claimOf(field);
        }
        var first = claimants(kind, claims)[0];
        return first ? first['.name'] : null;
    }
    opt._exclusiveOwner = ownerOf;  // exposed for unit tests

    var origWrite = opt.write;
    opt.write = function (section_id, value) {
        var first = ownerOf(section_id);
        if (first != null && first !== section_id) value = '0';
        if (typeof origWrite === 'function') return origWrite.call(this, section_id, value);
        return uci.set('singbox-ui', section_id, field.name, value);
    };
    var origRender = opt.renderWidget;
    if (typeof origRender === 'function') {
        opt.renderWidget = function (section_id, option_index, cfgvalue) {
            var first = ownerOf(section_id);
            var owned = (first != null && first !== section_id);
            var node = origRender.call(this, section_id, option_index, owned ? '0' : cfgvalue);
            if (owned && node && node.querySelectorAll) {
                node.querySelectorAll('input, select').forEach(function (el) { el.disabled = true; });
                // Array child ⇒ text node. A bare string child goes through
                // innerHTML in LuCI's dom.append() (verified in the container's
                // luci.js) and `first` is user-controlled.
                node.appendChild(E('div', { 'class': 'cbi-value-description' }, [
                    group
                        ? _('System routing / the firewall is already owned by inbound "%s". Only one inbound may own it.').format(first)
                        : _('nftables rules already active on inbound "%s"').format(first)
                ]));
            }
            return node;
        };
    }
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
        var noAdvGate = (kind === 'inbound' || kind === 'outbound');
        return values.map(function (v) {
            var d = {};
            d[discr] = protoName;
            if (f.depends) d[f.depends.field] = v;
            if (f.parent_enabled) d[f.parent_enabled] = '1';
            if (f.advanced && !noAdvGate) d['_show_advanced_' + f.tab] = '1';
            return d;
        });
    }

    materialized.fields.forEach(function (f) {
        var key = f.tab + '\t' + f.name;
        // Two-sided version gate: hide (compatOnly) or disable+note (default).
        // Fail-open when core version is unknown.
        var gate = versionGate(f);
        if (gate.mode === 'hide') return;   // compatOnly: drop incompatible field
        var registered = s._sbMatRegistry[key];
        if (registered) {
            // Same shared field appearing for another protocol: extend the
            // depends() chain with the new protocol's full gate (NOT just
            // discr=proto — that would bypass advanced/parent_enabled and
            // make the field unconditionally visible for the new protocol).
            depsArmsFor(f, protoName).forEach(function (d) {
                registered.opt.depends(d);
            });
            // Label resolution must not be coupled to protocol registration
            // order (audit 2.4). A single shared (tab,name) widget can carry
            // only one title, so we make the choice deterministic instead of
            // "first protocol in SB_*_PROTOCOLS wins": an explicit per-field
            // ui_label always beats a name-derived label, regardless of which
            // protocol was registered first. Reordering the protocol list can
            // therefore no longer silently drop a curated label.
            if (f.ui_label && !registered.explicitLabel) {
                registered.opt.title = _(labelFor(f));
                registered.explicitLabel = true;
            }
            if (!f.dynamic && Array.isArray(f.values))
                f.values.forEach(function (v) {
                    if (!registered.values[v]) {
                        registered.opt.value(v, v === '' ? _('(none)') : v);
                        registered.values[v] = 1;
                    }
                });
            return;
        }
        var W = widgetFor(f);
        var opt = s.taboption(f.tab, W, f.name, _(labelFor(f)));
        opt.modalonly = true;
        // Free entry on every checkbox dropdown ("-- custom --" row). MANDATORY
        // for netdev lists — eth0.100 / pppoe-wan are not enumerable and a strict
        // whitelist would make them unreachable — and correct for the rest: on a
        // LIST, `values` is a datalist of suggestions, not a whitelist (only
        // `enum` is strict), and a section reference may name a tag that comes
        // from a subscription rather than from a UCI section.
        if (W === form.MultiValue) opt.create = true;

        depsArmsFor(f, protoName).forEach(function (d) { opt.depends(d); });

        if (f.required)        opt.rmempty = false;
        if (f.default != null) opt.default = String(f.default);
        if (f.placeholder)     opt.placeholder = f.placeholder;
        // UX-2: surface per-field inline help when the descriptor carries it.
        // `ui_help` is optional and must be whitelisted in schema_dump.uc
        // FIELD_WHITELIST to reach the frontend. No-op when not declared.
        var help = f.ui_help;
        if (help) opt.description = _(help);

        var values = {};
        if (!f.dynamic && Array.isArray(f.values))
            f.values.forEach(function (v) {
                opt.value(v, v === '' ? _('(none)') : v);
                values[v] = 1;
            });

        if (f.dynamic) attachDynamic(opt, f);

        if (f.multiline) {
            opt.rows = 12;
            opt.monospace = true;
        }

        // A multiline field renders as a textarea (TextValue); password masking
        // and the eye-toggle only work on a single-line input, so multiline wins
        // for a field that is both (e.g. ssh private_key — a masked one-line PEM
        // is unusable). Such a field renders as a plain monospace textarea.
        if (f.secret && !f.multiline) {
            opt.password = true;
            decorateSecretInput(opt);
        }

        if (f.virtual) makeVirtual(opt);
        if (f.exclusive) makeExclusive(opt, f, kind);
        if (f.requires_pkg) attachPkgNote(opt, f.requires_pkg);

        attachValidator(opt, f.validate);
        if (gate.mode === 'disable') disableWithNote(opt, gate.note);
        tagField(opt, f.name, controlKindFor(W));
        s._sbMatRegistry[key] = {
            opt: opt, values: values,
            // Track whether THIS first registration already carried an explicit
            // ui_label, so a later protocol's explicit label only overrides a
            // name-derived one (audit 2.4) and explicit-vs-explicit stays stable.
            explicitLabel: !!f.ui_label,
        };
    });
}

// applyMaterializedNamed(s, kind, typeName, materialized) — render a singleton
// (NamedSection) descriptor: no type discriminator, no grid modal. Field
// vocabulary identical to applyMaterialized; version gate + advanced toggle +
// secret + dynamic + validators all reused. Fields with json_key are persisted
// by LuCI as ordinary NamedSection options.
function applyMaterializedNamed(s, kind, typeName, materialized) {
    if (!materialized || !Array.isArray(materialized.fields)) return;
    materialized.fields.forEach(function (f) {
        var gate = versionGate(f);
        if (gate.mode === 'hide') return;
        var W = widgetFor(f);
        var opt = s.option(W, f.name, _(labelFor(f)));
        if (W === form.MultiValue) opt.create = true;   // free entry — see applyMaterialized
        if (f.required)        opt.rmempty = false;
        if (f.default != null) opt.default = String(f.default);
        if (f.placeholder)     opt.placeholder = f.placeholder;
        var help = f.ui_help;
        if (help) opt.description = _(help);
        // depends arms: advanced toggle + per-value depends + parent_enabled.
        // No discriminator arm — singletons have a single type.
        if (f.depends) {
            var vals = Array.isArray(f.depends.value) ? f.depends.value : [f.depends.value];
            vals.forEach(function (v) {
                var d = {}; d[f.depends.field] = v;
                if (f.advanced) d['_show_advanced_' + f.tab] = '1';
                if (f.parent_enabled) d[f.parent_enabled] = '1';
                opt.depends(d);
            });
        } else if (f.advanced || f.parent_enabled) {
            // Combine advanced + parent_enabled into ONE arm so a field that
            // declares both (e.g. cache store_rdrc, clash external_ui) stays
            // hidden until BOTH the Advanced toggle AND the parent flag are on.
            // (A two-branch else-if would honor only the first and wrongly show
            // the field while the section is disabled.)
            var da = {};
            if (f.advanced)       da['_show_advanced_' + f.tab] = '1';
            if (f.parent_enabled) da[f.parent_enabled] = '1';
            opt.depends(da);
        }
        if (!f.dynamic && Array.isArray(f.values))
            f.values.forEach(function (v) { opt.value(v, v === '' ? _('(none)') : v); });
        if (f.dynamic) attachDynamic(opt, f);
        // Same rule as applyMaterialized: masking only works on a single-line
        // input, so a multiline secret stays a plain textarea.
        if (f.secret && !f.multiline) { opt.password = true; decorateSecretInput(opt); }
        if (f.virtual) makeVirtual(opt);
        if (f.requires_pkg) attachPkgNote(opt, f.requires_pkg);
        attachValidator(opt, f.validate);
        if (gate.mode === 'disable') disableWithNote(opt, gate.note);
        tagField(opt, f.name, controlKindFor(W));
    });
}

return L.Class.extend({
    applyMaterialized:      applyMaterialized,
    applyMaterializedNamed: applyMaterializedNamed,
    exclusiveConflicts:     exclusiveConflicts,
    warnExclusiveConflicts: warnExclusiveConflicts,
    tagField:               tagField,
    attachPkgNote:          attachPkgNote,
});
