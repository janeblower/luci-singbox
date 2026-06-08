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

var addRenameField      = SbCommon.addRenameField;
var openJsonImportModal = SbTabInbounds.openJsonImportModal;

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

	// C2.2.7: group the ~50 modal options into topical tabs so the modal
	// stops scrolling forever. Tab assignment is purely visual — the
	// depends()/validate()/write()/cfgvalue() chains below are unchanged.
	s.tab('basic',       _('Basic'));
	s.tab('credentials', _('Credentials'));
	s.tab('tls',         _('TLS'));
	s.tab('transport',   _('Transport'));
	s.tab('multiplex',   _('Multiplex'));
	s.tab('advanced',    _('Advanced'));

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
		if (t === 'url')          return uci.get('singbox-ui', section_id, 'proxy_url') ? '(share-link)' : '—';
		if (t === 'interface')    return uci.get('singbox-ui', section_id, 'interface') || '—';
		var srv = uci.get('singbox-ui', section_id, 'server')      || '';
		var prt = uci.get('singbox-ui', section_id, 'server_port') || '';
		return srv && prt ? srv + ':' + prt : (srv || '—');
	};

	o = s.taboption('basic', form.ListValue, 'type', _('Type'));
	o.value('vless',        'VLESS');
	o.value('vmess',        'VMess');
	o.value('trojan',       'Trojan');
	o.value('hysteria2',    'Hysteria2');
	o.value('shadowsocks',  'Shadowsocks');
	o.value('tuic',         'TUIC');
	o.value('anytls',       'AnyTLS');
	o.value('ssh',          'SSH');
	o.value('interface',    _('Direct (interface)'));
	o.value('url',          _('Share-link URL'));
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	// D2: descriptor-driven UI. Each proxy protocol's UCI fields are emitted
	// from window.singboxUiSchemaCache.outbound[<proto>]. This replaces the
	// pre-D2 hand-coded depends('type', '<proto>') chains for the 8
	// descriptor-owned types (vless/vmess/trojan/hysteria2/shadowsocks/tuic/
	// anytls/ssh). Non-proxy types (interface/url/subscription) remain below.
	var schema = (window.singboxUiSchemaCache || {}).outbound || {};
	Object.keys(schema).forEach(function(protoName) {
		descriptor_form.applyDescriptor(s, 'outbound', protoName, schema[protoName]);
	});

	// Basic-tab fields specific to the non-proxy outbound types
	// (interface / url / subscription). They share the basic tab with
	// type/server/server_port so the form's primary identity stays grouped.
	o = s.taboption('basic', widgets.DeviceSelect, 'interface', _('Interface'));
	o.modalonly = true;
	o.noaliases = true;
	o.depends('type', 'interface');
	o.description = _('For a direct-via-WAN outbound, pick the real WAN device (may differ from "wan").');

	o = s.taboption('basic', form.Value, 'proxy_url', _('URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'vless:// | vmess:// | ss:// | trojan:// | hy2://';
	o.description = _('Share-link URL. Supported schemes: vless://, vmess:// (v2rayN base64-JSON), ss://, trojan://, hy2:// / hysteria2://.');
	o.depends('type', 'url');

	o = s.taboption('basic', form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('type', 'subscription');

	o = s.taboption('basic', form.ListValue, 'sub_update_via', _('Update via'));
	o.modalonly = true;
	o.depends('type', 'subscription');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		this.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec.type === 'interface')
				this.value(sec['.name'], sec['.name'] + ' (' + (sec.interface || '?') + ')');
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
	buildOutboundsMap: buildOutboundsMap,
});
