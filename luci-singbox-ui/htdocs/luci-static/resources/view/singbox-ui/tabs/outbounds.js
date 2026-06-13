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

var addRenameField      = SbCommon.addRenameField;
var openJsonImportModal = SbTabInbounds.openJsonImportModal;

var SB_OUTBOUND_PROTOCOLS = [
	['direct',       'Direct (interface bind)'],
	['shadowsocks',  'Shadowsocks'],
	['vless',        'VLESS'],
	['trojan',       'Trojan'],
	['hysteria2',    'Hysteria2'],
	['subscription', 'Subscription URL']
];

function openShareLinkModal(m) {
	var ta = E('textarea', {
		'rows': 4, 'class': 'cbi-input-textarea',
		'style': 'width:100%;font-family:monospace;',
		'placeholder': 'vless://… or ss://… or trojan://… or hysteria2://…'
	});
	var err = E('div', { 'style': 'color:#c33;margin-top:8px;' });

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
		ui.addNotification(null,
			E('p', {}, _('Imported. Press "Save & Apply" to commit.')),
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
	addRenameField(s);

	// E2: only the basic tab here. TLS/Transport/Multiplex/Dial tabs are
	// created on demand by descriptor_form.applyMaterialized after the
	// per-protocol fields are attached (see inbounds.js note).
	s.tab('basic', _('Basic'));

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

	var o;
	o = s.taboption('basic', form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	// Per-row Export JSON button. Mirror of the inbound grid: GridSection
	// renders form.Button as an inline action cell so users get the JSON for
	// the row they clicked, not the whole config.
	o = s.taboption('basic', form.Button, '_export', _('JSON'));
	o.editable = true;
	o.modalonly = false;
	o.inputtitle = _('Export');
	o.inputstyle = 'action';
	o.onclick = function (ev, section_id) {
		SbImpOutbound.jsonExportOutbound(section_id);
		return false;
	};

	o = s.taboption('basic', form.DummyValue, '_address', _('Address'));
	o.modalonly = false;
	o.editable  = false;
	o.cfgvalue  = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'type') || '';
		if (t === 'subscription') return uci.get('singbox-ui', section_id, 'sub_url') || '—';
		if (t === 'direct')       return uci.get('singbox-ui', section_id, 'bind_interface') || '(default)';
		var srv = uci.get('singbox-ui', section_id, 'server')      || '';
		var prt = uci.get('singbox-ui', section_id, 'server_port') || '';
		return srv && prt ? srv + ':' + prt : (srv || '—');
	};

	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	o.value('direct',       _('Direct (interface bind)'));
	o.value('shadowsocks',  'Shadowsocks');
	o.value('vless',        'VLESS');
	o.value('trojan',       'Trojan');
	o.value('hysteria2',    'Hysteria2');
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	// E2: descriptor-driven UI for all stored outbound types.
	// subscription has its own UCI shape and is handled by the fields below.
	var outboundSchema = (SbViewState.getSchema() || {}).outbound || {};
	SB_OUTBOUND_PROTOCOLS.forEach(function (entry) {
		var protoName = entry[0];
		if (protoName === 'subscription') return;  // subscription has its own UCI shape
		var mat = outboundSchema[protoName];
		if (mat) descriptor_form.applyMaterialized(s, 'outbound', protoName, mat);
	});

	// Basic-tab fields specific to subscription outbound type.
	o = s.taboption('basic', form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.ListValue, 'sub_update_via', _('Update via'));
	o.modalonly = true;
	o.depends('type', 'subscription');
	o.description = _('Fetch the subscription through this outbound (proxy or direct).');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		this.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec['.name'] === section_id) return;       // not itself
			if (sec.type === 'subscription') return;        // can't fetch through a subscription
			var label = sec['.name'] + ' (' + (sec.type || '?') + ')';
			this.value(sec['.name'], label);
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
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

	return m;
}

return L.Class.extend({
	SB_OUTBOUND_PROTOCOLS: SB_OUTBOUND_PROTOCOLS,
	openShareLinkModal:    openShareLinkModal,
	buildOutboundsMap:     buildOutboundsMap,
});
