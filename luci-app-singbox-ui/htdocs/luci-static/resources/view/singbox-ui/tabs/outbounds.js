'use strict';
'require form';
'require rpc';
'require uci';
'require ui';
'require tools.widgets as widgets';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.validators as SbValidators';
'require view.singbox-ui.lib.descriptor_form as descriptor_form';
'require view.singbox-ui.importers.outbound as SbImpOutbound';
'require view.singbox-ui.tabs.inbounds as SbTabInbounds';
'require view.singbox-ui.lib.view_state as SbViewState';
'require view.singbox-ui.lib.json_editor as SbJsonEditor';

var addRenameField      = SbCommon.addRenameField;
var openJsonImportModal = SbTabInbounds.openJsonImportModal;

var _pluginTypes = [];
function setPluginOutboundTypes(types) { _pluginTypes = types || []; }

var _plugins = [];
function setPluginFormRenderers(plugins) { _plugins = plugins || []; }

// formRendererFor — returns the renderOutboundForm fn bound to the plugin api,
// or null if no plugin owns this outbound type.
function formRendererFor(type) {
	for (var i = 0; i < _plugins.length; i++) {
		var p = _plugins[i];
		if (p.api && p.api.renderOutboundForm && p.api.outboundTypes) {
			var has = p.api.outboundTypes().some(function (t) { return t[0] === type; });
			if (has) return p.api.renderOutboundForm.bind(p.api);
		}
	}
	return null;
}

var SB_OUTBOUND_PROTOCOLS = [
	['direct',       'Direct (interface bind)'],
	['socks',        'SOCKS'],
	['http',         'HTTP'],
	['shadowsocks',  'Shadowsocks'],
	['vmess',        'VMess'],
	['vless',        'VLESS'],
	['trojan',       'Trojan'],
	['hysteria',     'Hysteria'],
	['hysteria2',    'Hysteria2'],
	['tuic',         'TUIC'],
	['anytls',       'AnyTLS'],
	['shadowtls',    'ShadowTLS'],
	['naive',        'Naive'],
	['ssh',          'SSH'],
	['selector',     'Selector'],
	['urltest',      'URLTest'],
	['subscription', 'Subscription URL']
];

// The Type dropdown mixes three unrelated things: 17 hand-configured protocols, a
// subscription URL, and the two group kinds. `_kind` splits them into a first
// step, and `type` is then filtered down to that step's members.
//
// The kind is DERIVED from `type` rather than stored: a second persisted
// discriminator would be a second thing that can disagree with the first. Plugin
// outbound types fall through to `manual`, which is what they are.
function kindOfType(t) {
	if (t === 'subscription')                 return 'subscription';
	if (t === 'selector' || t === 'urltest')  return 'group';
	return 'manual';
}

function openShareLinkModal(m) {
	var ta = E('textarea', {
		'rows': 4, 'class': 'cbi-input-textarea',
		'style': 'width:100%;font-family:monospace;',
		'placeholder': 'vless://… or ss://… or trojan://… or hysteria2://…'
	});
	var err = E('div', { 'class': 'sb-error', 'style': 'margin-top:8px;' });

	function onImport() {
		err.textContent = '';
		var url = (ta.value || '').trim();
		if (!url) { err.textContent = _('Empty URL'); return; }
		var res = SbImpOutbound.shareLinkImport(url);
		if (!res.ok) { err.textContent = res.errors.join('; '); return; }
		var base = (res.fields.type || 'import') + '_out';
		var sid = base, i = 1;
		while (uci.get('singbox-ui', sid)) sid = base + '_' + (i++);
		uci.add('singbox-ui', 'outbound', sid);
		uci.set('singbox-ui', sid, 'enabled', '1');
		Object.keys(res.fields).forEach(function (k) {
			var v = res.fields[k];
			if (Array.isArray(v)) uci.set('singbox-ui', sid, k, v.map(String));
			else                  uci.set('singbox-ui', sid, k, String(v));
		});
		ui.hideModal();
		// UX-4: name the generated section so the user can find the new draft
		// row without a reload/scroll (which would race handleSave).
		ui.addNotification(null,
			E('p', {}, _('Imported as "%s". Press "Save & Apply" to commit.').format(sid)),
			'info');
	}

	ui.showModal(_('Import share-link'), [
		E('p', {}, _('Paste a vless://, ss://, trojan:// or hysteria2:// link.')),
		ta, err,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-positive', 'click': onImport }, _('Import'))
		])
	]);
}

function buildOutboundsMap() {
	var m = new form.Map('singbox-ui', _('Outbounds'),
		_('Define outbounds: direct via interface, share-link URL, subscription, or proxy constructor.'));

	var s = m.section(form.GridSection, 'outbound', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'type') || '';
		return _('Outbound') + ': ' + section_id + (t ? ' (' + _(t) + ')' : '');
	};
	// E2: only the basic tab here. TLS/Transport/Multiplex/Dial tabs are
	// created on demand by descriptor_form.applyMaterialized after the
	// per-protocol fields are attached (see inbounds.js note).
	s.tab('basic', _('Basic'));

	// The built-in `wan` outbound: same read-only treatment as the built-in
	// rule-sets. No hide predicate — it has no master switch; generate.uc simply
	// stops emitting it once nothing references it.
	SbCommon.lockBuiltinRow(s,
		_('Built-in outbound — managed by the package. It is dropped from the config as soon as nothing routes to it.'));

	addRenameField(s, 'basic');

	var origRenderSectionAddOut = s.renderSectionAdd;
	s.renderSectionAdd = function () {
		var node = origRenderSectionAddOut.apply(this, arguments);
		var btn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:8px;',
			'click': ui.createHandlerFn(this, function () {
				openJsonImportModal('outbound', m);
				return false;
			})
		}, _('Import JSON'));
		if (node && node.appendChild) node.appendChild(btn);
		var linkBtn = E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'margin-left:6px;',
			'click': ui.createHandlerFn(this, function () {
				openShareLinkModal(m);
				return false;
			})
		}, _('Import share-link'));
		if (node && node.appendChild) node.appendChild(linkBtn);
		return node;
	};

	// H3: pin a distinct, generated X-HWID to each subscription outbound at
	// creation. subscription.uc hwid_for() already prefers an explicit
	// sub_hwid over the router-derived one (same for every subscription) —
	// only the frontend needs to write one in, once, for that section.
	// Must fire ONLY for sections created in THIS editing session: an
	// EXISTING subscription's device binding must not change just because
	// its modal was opened/saved (NO-migration). The field's own
	// load/cfgvalue fires for existing sections too and can't tell new from
	// old, so hook handleAdd instead — name IS the section id here
	// (s.anonymous = false). newOutboundSids is consulted by sub_hwid's own
	// parse() override below (map.save() is NOT the right hook: GridSection's
	// modal builds a throwaway CBIMap per open — see renderMoreOptionsModal/
	// handleModalSave in form.js — whose own .save() does the real parse+write;
	// the outer m.save() we control is never called on a normal Add).
	var newOutboundSids = {};
	var origHandleAdd = s.handleAdd;
	s.handleAdd = function (ev, name) {
		newOutboundSids[name] = true;
		return origHandleAdd.apply(this, arguments);
	};

	function genHwid() {
		var b = new Uint8Array(8);
		if (window.crypto && crypto.getRandomValues) crypto.getRandomValues(b);
		else for (var i = 0; i < 8; i++) b[i] = Math.floor(Math.random() * 256);
		var hex = Array.prototype.map.call(b, function (x) {
			return (x < 16 ? '0' : '') + x.toString(16);
		}).join('');
		return hex.slice(0, 4) + '-' + hex.slice(4, 8) + '-' + hex.slice(8, 12) + '-' + hex.slice(12, 16);
	}

	var o;
	o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	// Per-row Export JSON column + the "JSON editor" button inside the modal.
	// Both are greyed out on a subscription: it is a URL that expands into many
	// outbounds, so there is no single object to show or to edit.
	SbJsonEditor.addJsonButtons(s, 'outbound', form);

	o = s.taboption('basic', form.DummyValue, '_address', _('Address'));
	o.modalonly = false;
	o.editable  = false;
	o.cfgvalue  = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'type') || '';
		if (t === 'subscription') {
			// The subscription URL usually carries the account token in its path or
			// query. The edit modal masks it; this column is always on screen, so it
			// showed the secret to anyone glancing at (or screenshotting) the page.
			// Host only — enough to tell subscriptions apart, nothing to steal.
			var u = uci.get('singbox-ui', section_id, 'sub_url') || '';
			if (!u) return '—';
			var m = u.match(/^[a-z][a-z0-9+.-]*:\/\/([^/?#]+)/i);
			return m ? m[1] + '/…' : '…';
		}
		if (t === 'direct')       return uci.get('singbox-ui', section_id, 'bind_interface') || '(default)';
		if (t === 'selector' || t === 'urltest') {
			var members = uci.get('singbox-ui', section_id, 'group_outbounds');
			var n = Array.isArray(members) ? members.length : (members ? 1 : 0);
			return _('group') + ' (' + n + ')';
		}
		var srv = uci.get('singbox-ui', section_id, 'server')      || '';
		var prt = uci.get('singbox-ui', section_id, 'server_port') || '';
		return srv && prt ? srv + ':' + prt : (srv || '—');
	};

	// --- Step 1 of the type picker: the mode. ------------------------------
	// Session-only: the mode is derived from `type` on every open and never
	// written. `type` has to stay the ONE discriminator — every descriptor
	// depends() arm keys off it — and a second persisted field would just be a
	// second thing that can disagree with the first.
	var typeApply = {};   // section_id -> fn(kind, reset) installed by `type` below

	o = s.taboption('basic', form.ListValue, '_kind', _('Mode'));
	o.modalonly = true;
	o.value('manual',       _('Manual'));
	o.value('group',        _('Groups (URLTest/Selector)'));
	o.value('subscription', _('Subscription'));
	o.write    = function () {};
	o.remove   = function () {};
	o.cfgvalue = function (section_id) {
		return kindOfType(uci.get('singbox-ui', section_id, 'type') || '');
	};
	var origKindRender = o.renderWidget;
	o.renderWidget = function (section_id, option_index, cfgvalue) {
		var node = origKindRender.call(this, section_id, option_index, cfgvalue);
		var sel = (node.tagName === 'SELECT') ? node
			: (node.querySelector && node.querySelector('select'));
		// The listener only ever fires on user interaction, long after `type` has
		// registered its apply fn — so declaring _kind first is safe.
		if (sel) sel.addEventListener('change', function () {
			var apply = typeApply[section_id];
			if (apply) apply(sel.value, true);
		});
		return node;
	};

	// --- Step 2: the type itself, filtered down to the chosen mode. ---------
	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	var allTypes = SB_OUTBOUND_PROTOCOLS.concat(_pluginTypes);
	allTypes.forEach(function (e) { o.value(e[0], _(e[1])); });
	o.rmempty = false;
	SbCommon.applyVersionGate(o,
		(SbViewState.getSchema() || {}).outbound || {},
		SbViewState.getCoreVersion(), SbViewState.getCompatOnly());

	// Wrap AFTER applyVersionGate so we filter the node the gate produced.
	// The gate owns `disabled` (it greys out types the running core is too old
	// for); we own `hidden`. Clearing `disabled` here would silently re-offer a
	// type sing-box would reject.
	var origTypeRender = o.renderWidget;
	o.renderWidget = function (section_id, option_index, cfgvalue) {
		var node = origTypeRender.call(this, section_id, option_index, cfgvalue);
		var sel = (node.tagName === 'SELECT') ? node
			: (node.querySelector && node.querySelector('select'));
		if (!sel) return node;

		function apply(kind, reset) {
			var first = null;
			Array.prototype.slice.call(sel.options).forEach(function (opt) {
				var ok = (kindOfType(opt.value) === kind);
				opt.hidden = !ok;
				if (ok && !opt.disabled && first === null) first = opt.value;
			});
			if (reset && kindOfType(sel.value) !== kind && first !== null) {
				sel.value = first;
				// LuCI's ui.Select re-dispatches a native `change` on the <select>
				// as `widget-change`, which is what drives depends() — so the
				// descriptor fields for the new type appear.
				sel.dispatchEvent(new Event('change', { bubbles: true }));
			}
			// `subscription` is the only member of its kind, and a one-item
			// dropdown is noise. Hide the ROW — never a depends(), which would make
			// LuCI treat `type` as inactive and parse() would then DELETE it.
			var row = sel.closest ? sel.closest('.cbi-value') : null;
			if (row) row.style.display = (kind === 'subscription') ? 'none' : '';
		}
		typeApply[section_id] = apply;

		var kind = kindOfType(cfgvalue || sel.value || '');
		apply(kind, false);
		// renderWidget returns before CBI wraps the widget in its .cbi-value row,
		// so the row is not reachable yet on this first pass — re-run once the DOM
		// is assembled, otherwise an existing subscription opens with a pointless
		// one-item Type dropdown showing.
		window.setTimeout(function () { apply(kind, false); }, 0);
		return node;
	};

	// E2: descriptor-driven UI for all stored outbound types.
	// subscription has its own UCI shape and is handled by the fields below.
	var outboundSchema = (SbViewState.getSchema() || {}).outbound || {};
	SB_OUTBOUND_PROTOCOLS.forEach(function (entry) {
		var protoName = entry[0];
		if (protoName === 'subscription') return;  // subscription has its own UCI shape
		var mat = outboundSchema[protoName];
		if (mat) descriptor_form.applyMaterialized(s, 'outbound', protoName, mat);
	});

	// Plugin-contributed outbound types: delegate to the plugin's renderOutboundForm.
	// ctx shape: { section: s, map: m } — the plugin adds options directly to s.
	_pluginTypes.forEach(function (entry) {
		var protoName = entry[0];
		var renderer = formRendererFor(protoName);
		if (renderer) renderer(protoName, null, { section: s, map: m });
	});

	// Basic-tab fields specific to subscription outbound type.
	o = s.taboption('basic', form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('type', 'subscription');
	// sub_url is the one mandatory field of a subscription outbound — without it
	// the outbound silently fetches nothing and the failure only surfaces later
	// in logread (BUG-1). rmempty=false blocks Save & Apply on an empty value;
	// the validate additionally requires an http(s):// shape so a typo'd value
	// is caught inline rather than producing a dead outbound.
	o.rmempty  = false;
	o.validate = function (_section_id, value) {
		// depends() means this only renders for type=subscription; an empty
		// value here is the required-field violation rmempty=false reports.
		if (value == null || value === '') return true;
		return SbValidators.url(value);
	};

	// A panel serves a DIFFERENT body per User-Agent (Clash YAML here, a base64
	// URI list there, an HTML "open in the app" stub for a browser UA). The
	// backend therefore rotates through the known client profiles until a body
	// actually parses — a free-text UA would only pin it to one guess. Pick a
	// profile ID, not a UA string; empty = start with Happ and rotate. New
	// outbounds default to 'happ' explicitly (H2): Happ's per-location format
	// groups nodes, where the sing-box UA yields a flat list.
	o = s.taboption('basic', form.ListValue, 'sub_user_agent', _('User-Agent'));
	o.modalonly = true;
	o.depends('type', 'subscription');
	o.description = _('Client profile whose User-Agent is sent when fetching. Tried first; if the provider answers with something unparseable, the other profiles are tried in turn.');
	o.value('', _('Automatic (Happ, then others)'));
	o.value('sing-box', 'sing-box');
	o.value('happ', 'Happ');
	o.value('v2rayn', 'v2rayN');
	o.value('v2rayng', 'v2rayNG');
	o.value('mihomo', 'Mihomo');
	o.value('clash.meta', 'Clash.Meta');
	o.default = 'happ';

	// Remnawave/Happ-style panels bind a config to a device: without an X-HWID
	// they hand back an empty body. The default is derived from the router's MAC
	// and model, which is stable across reboots and needs no user action.
	o = s.taboption('basic', form.Flag, 'sub_auto_hwid', _('Automatic HWID'));
	o.modalonly = true;
	o.default   = '1';
	o.depends('type', 'subscription');
	o.description = _('Send an X-HWID header derived from this router (MAC + model). Required by panels that bind a subscription to one device.');

	o = s.taboption('basic', form.Value, 'sub_hwid', _('HWID'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'xxxx-xxxx-xxxx-xxxx';
	o.depends('type', 'subscription');
	o.description = _('Override the hardware ID sent to the provider. Leave empty to use the automatic one.');
	// H3: on Save, if this is a section created THIS session (newOutboundSids),
	// its type is subscription, and the user left HWID blank, pin a generated
	// one instead of leaving it empty. AbstractValue.parse() skips write()
	// entirely for an empty formvalue (it calls remove() instead), so the hook
	// has to sit here, not on write(). GridSection.cloneOptions() (form.js)
	// copies this own-property override onto the modal's throwaway clone, the
	// same mechanism sub_url's custom validate above already relies on. The
	// 'type' option is declared earlier in this section, so by the time this
	// parse() runs its write() has already landed in the uci changeset.
	var origSubHwidParse = o.parse;
	o.parse = function (section_id) {
		if (newOutboundSids[section_id] && !this.formvalue(section_id) &&
		    uci.get('singbox-ui', section_id, 'type') === 'subscription') {
			return Promise.resolve(this.write(section_id, genHwid()));
		}
		return origSubHwidParse.apply(this, arguments);
	};

	// Bootstrapping case: the panel itself is blocked, so the only route to it is
	// the tunnel the panel is supposed to configure. Point this at a local
	// socks/mixed inbound of the running sing-box.
	o = s.taboption('basic', form.Value, 'sub_proxy', _('Fetch via proxy'));
	o.modalonly   = true;
	o.placeholder = 'socks5h://127.0.0.1:2080';
	o.depends('type', 'subscription');
	o.description = _('Fetch this subscription through a proxy (e.g. a local mixed/socks inbound), for providers whose panel is unreachable directly. Leave empty to fetch directly.');
	o.validate = function (_sid, v) {
		if (!v) return true;
		return /^(socks5h|socks5|socks4a|socks4|https?):\/\/[A-Za-z0-9._~%@:-]+:\d{1,5}$/.test(v)
			? true : _('Expected scheme://host:port, e.g. socks5h://127.0.0.1:2080');
	};

	o = s.taboption('basic', form.Value, 'sub_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '3600';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.Flag, 'sub_multi', _('Expand to selector'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.ListValue, 'sub_selector_type', _('Selector type'));
	o.modalonly = true;
	o.value('selector', 'selector');
	o.value('urltest',  'urltest');
	o.default = 'selector';
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Value, 'sub_urltest_url', _('URL-test URL'));
	o.modalonly   = true;
	o.placeholder = 'https://www.gstatic.com/generate_204';
	o.depends({ type: 'subscription', sub_multi: '1', sub_selector_type: 'urltest' });

	// Filters act on the node's display name (the provider's "🇳🇱 Amsterdam"),
	// never on the tag — the tag is what a selector pick is pinned to.
	o = s.taboption('basic', form.Value, 'sub_include_regex', _('Include nodes (regex)'));
	o.modalonly   = true;
	o.placeholder = 'Premium|Direct';
	o.description = _('Keep only nodes whose name matches. Empty = keep all.');
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Value, 'sub_exclude_regex', _('Exclude nodes (regex)'));
	o.modalonly   = true;
	o.placeholder = 'Trial|Expire';
	o.description = _('Drop nodes whose name matches. Applied after the include filter.');
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Value, 'sub_include_countries', _('Countries'));
	o.modalonly   = true;
	o.placeholder = 'NL,DE,SE';
	o.description = _('Comma-separated ISO country codes, matched against the flag emoji in the node name. Empty = all countries.');
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Value, 'sub_node_prefix', _('Node name prefix'));
	o.modalonly   = true;
	o.description = _('Prepended to the display name of imported nodes. Does not change the tag.');
	o.depends({ type: 'subscription', sub_multi: '1' });

	o = s.taboption('basic', form.Flag, 'sub_import_groups', _('Import subscription groups'));
	o.modalonly = true;
	o.default   = '0';
	o.depends({ type: 'subscription', sub_multi: '1' });
	o.description = _('Import URLTest/selector groups the provider ships (country groups, detour cascades). Off by default: turning it on changes the selector membership, which can move your saved node pick.');

	o = s.taboption('basic', form.Flag, 'sub_hide_grouped_nodes', _('Hide grouped nodes'));
	o.modalonly = true;
	o.default   = '1';
	o.depends({ type: 'subscription', sub_multi: '1', sub_import_groups: '1' });
	o.description = _('Hide nodes that are already inside an imported group, or used only as a detour hop, from the top selector. They stay routable.');

	o = s.taboption('basic', form.Value, 'sub_group_max_depth', _('Max group nesting'));
	o.modalonly   = true;
	o.datatype    = 'range(1,16)';
	o.placeholder = '3';
	o.default     = '3';
	o.depends({ type: 'subscription', sub_multi: '1', sub_import_groups: '1' });

	o = s.taboption('basic', form.Flag, 'sub_trust_provider', _('Trust provider routing'));
	o.modalonly = true;
	o.default   = '0';
	o.depends({ type: 'subscription', sub_multi: '1', sub_import_groups: '1' });
	o.description = _('Allow the provider to route imported nodes directly (detour to direct/block), bypassing the proxy for those nodes. Unsafe — leave off unless you trust the feed.');

	o = s.taboption('basic', form.Flag, 'sub_cache_persist', _('Persist cache to flash'));
	o.modalonly = true;
	o.default   = '1';
	o.depends('type', 'subscription');
	o.description = _('Keep a last-known-good copy on flash so the subscription survives a reboot. Off = cache only in RAM (lost on reboot); avoids writing node passwords to flash.');

	return m;
}

return L.Class.extend({
	SB_OUTBOUND_PROTOCOLS:    SB_OUTBOUND_PROTOCOLS,
	kindOfType:               kindOfType,
	openShareLinkModal:       openShareLinkModal,
	buildOutboundsMap:        buildOutboundsMap,
	setPluginOutboundTypes:   setPluginOutboundTypes,
	setPluginFormRenderers:   setPluginFormRenderers,
});
