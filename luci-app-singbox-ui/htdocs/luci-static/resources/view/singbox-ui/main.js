'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require rpc';
'require tools.widgets as widgets';

var callRefresh    = rpc.declare({ object: 'singbox-ui', method: 'refresh',     params: [ 'what' ] });
var callRestart    = rpc.declare({ object: 'singbox-ui', method: 'restart' });
var callStatus     = rpc.declare({ object: 'singbox-ui', method: 'status' });
var callReadConfig = rpc.declare({ object: 'singbox-ui', method: 'read_config' });

// Insert a synthetic "Name" field as the first option of a GridSection's
// edit modal. cfgvalue returns the section id, write triggers uci.rename.
// We don't write a real UCI option; remove() is a no-op for the same reason.
function addRenameField(s) {
	var o = s.option(form.Value, '__rename', _('Name'));
	o.modalonly = true;
	o.rmempty   = false;
	o.datatype  = 'and(minlength(1), uciname)';
	o.cfgvalue  = function (section_id) { return section_id; };
	o.write     = function (section_id, value) {
		if (value && value !== section_id)
			uci.rename('singbox-ui', section_id, value);
	};
	o.remove = function () {};
}

var TextareaValue = form.Value.extend({
	renderWidget: function (section_id, option_index, cfgvalue) {
		return E('textarea', {
			'name':  this.cbid(section_id),
			'class': 'cbi-input-textarea',
			'rows':  5,
			'style': 'width:100%;font-family:monospace'
		}, [ cfgvalue != null ? cfgvalue : '' ]);
	},
	formvalue: function (section_id) {
		var node = this.map.findElement('name', this.cbid(section_id));
		return node ? node.value : null;
	},
	validate: function (section_id, value) {
		if (value == null || value === '') return true;
		try { JSON.parse(value); return true; }
		catch (e) { return _('Invalid JSON: ') + e.message; }
	}
});

function buildInputMap() {
	var m = new form.Map('singbox-ui', _('Input'),
		_('Configure FakeIP and TProxy inbound. ' +
		  'nftables redirect rules are applied automatically ' +
		  'when TProxy is enabled and the service starts.'));

	var s, o;

	s = m.section(form.NamedSection, 'fakeip', 'fakeip', _('FakeIP'));
	s.anonymous = true;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.rmempty = false;
	o = s.option(form.Value, 'inet4_range', _('IPv4 range'));
	o.datatype = 'cidr4';
	o.placeholder = '198.18.0.0/15';
	o = s.option(form.Value, 'inet6_range', _('IPv6 range'));
	o.datatype = 'cidr6';
	o.placeholder = 'fc00::/18';

	s = m.section(form.NamedSection, 'tproxy', 'tproxy', _('TProxy Inbound'));
	s.anonymous = true;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.rmempty = false;
	o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
	o.noaliases = true;
	o = s.option(form.Value, 'port', _('Port'));
	o.datatype = 'port';
	o.placeholder = '7893';

	return m;
}

function buildOutboundsMap() {
	var m = new form.Map('singbox-ui', _('Outbounds'),
		_('Define outbounds: direct, block, or proxy via interface / URL / raw JSON / subscription.'));

	var s = m.section(form.GridSection, 'outbound', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) {
		var t = uci.get('singbox-ui', section_id, 'proxy_type') || '';
		return _('Outbound') + ': ' + section_id + (t ? ' (' + _(t) + ')' : '');
	};
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.ListValue, 'proxy_type', _('Type'));
	o.value('interface',    _('Interface'));
	o.value('url',          _('URL (share link)'));
	o.value('json',         _('Raw JSON'));
	o.value('subscription', _('Subscription URL'));
	o.rmempty = false;

	o = s.option(widgets.DeviceSelect, 'interface', _('Interface'));
	o.modalonly = true;
	o.noaliases = true;
	o.depends('proxy_type', 'interface');

	o = s.option(form.Value, 'proxy_url', _('URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'vless://uuid@host:443?security=tls&sni=host';
	o.depends('proxy_type', 'url');

	o = s.option(TextareaValue, 'proxy_json', _('JSON outbound'));
	o.modalonly   = true;
	o.placeholder = '{"type":"vless","server":"host","server_port":443,"uuid":"..."}';
	o.depends('proxy_type', 'json');

	o = s.option(form.Value, 'sub_url', _('Subscription URL'));
	o.modalonly   = true;
	o.password    = true;
	o.placeholder = 'https://sub.example.com/config';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.ListValue, 'sub_update_via', _('Update via'));
	o.modalonly = true;
	o.depends('proxy_type', 'subscription');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		this.value('direct', _('Direct (WAN)'));
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			if (sec.proxy_type === 'interface')
				this.value(sec['.name'], sec['.name'] + ' (' + (sec.interface || '?') + ')');
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};

	o = s.option(form.Value, 'sub_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '3600';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.Flag, 'sub_multi', _('Expand to selector'));
	o.modalonly = true;
	o.default   = '0';
	o.depends('proxy_type', 'subscription');

	o = s.option(form.ListValue, 'sub_selector_type', _('Selector type'));
	o.modalonly = true;
	o.value('selector', 'selector');
	o.value('urltest',  'urltest');
	o.default = 'selector';
	o.depends({ proxy_type: 'subscription', sub_multi: '1' });

	o = s.option(form.Value, 'sub_urltest_url', _('URL-test URL'));
	o.modalonly   = true;
	o.placeholder = 'https://www.gstatic.com/generate_204';
	o.depends({ proxy_type: 'subscription', sub_multi: '1', sub_selector_type: 'urltest' });

	return m;
}

function buildRulesetsMap() {
	var m = new form.Map('singbox-ui', _('Rule-Sets'),
		_('Remote (.srs/.json) or local rule-sets, referenced by route rules.'));

	var s = m.section(form.GridSection, 'ruleset', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) { return _('Rule-Set') + ': ' + section_id; };
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.ListValue, 'type', _('Type'));
	o.value('remote', _('Remote'));
	o.value('local',  _('Local'));
	o.default = 'remote';
	o.rmempty = false;

	o = s.option(form.Value, 'url', _('URL'));
	o.placeholder = 'https://example.com/geosite.srs';
	o.depends('type', 'remote');

	o = s.option(form.Value, 'path', _('Path'));
	o.modalonly   = true;
	o.placeholder = '/etc/singbox-ui/rules/cn.json';
	o.depends('type', 'local');

	// Format is auto-detected from the file extension by subscription.uc
	// and generate.uc (.srs → binary, .json → source). No UI field.

	o = s.option(form.Flag, 'dns_fakeip', _('Route DNS to FakeIP'));
	o.modalonly = true;
	o.default   = '0';

	o = s.option(form.Value, 'dns_fakeip_tag', _('FakeIP DNS tag'));
	o.modalonly   = true;
	o.placeholder = 'fakeip';
	o.depends('dns_fakeip', '1');

	o = s.option(form.Flag, 'nft_rules', _('Create nftables rules'));
	o.modalonly = true;
	o.default   = '0';

	o = s.option(form.Value, 'update_interval', _('Update interval (s)'));
	o.modalonly   = true;
	o.datatype    = 'uinteger';
	o.placeholder = '86400';
	o.depends('type', 'remote');

	return m;
}

function buildRouteRulesMap() {
	var m = new form.Map('singbox-ui', _('Route Rules'),
		_('Match traffic against one or more rule-sets and send it to an outbound, direct, or block.'));

	var s = m.section(form.GridSection, 'route_rule', null);
	s.anonymous  = false;
	s.addremove  = true;
	s.sortable   = true;
	s.modaltitle = function (section_id) { return _('Route Rule') + ': ' + section_id; };
	addRenameField(s);

	var o;
	o = s.option(form.Flag, 'enabled', _('Enable'));
	o.default  = '1';
	o.editable = true;

	o = s.option(form.MultiValue, 'ruleset', _('Rule-Sets'));
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		uci.sections('singbox-ui', 'ruleset').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.MultiValue.prototype.load.apply(this, arguments);
	};

	o = s.option(form.ListValue, 'action', _('Action'));
	o.value('direct',   _('Direct'));
	o.value('block',    _('Block'));
	o.value('outbound', _('Outbound'));
	o.default = 'direct';
	o.rmempty = false;

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'outbound');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};

	return m;
}

function buildRouteDefaultMap() {
	var m = new form.Map('singbox-ui', _('Default'),
		_('Final route applied to traffic that does not match any rule.'));

	var s = m.section(form.NamedSection, 'route_default', 'route_default', _('Default'));
	s.anonymous = true;

	var o;
	o = s.option(form.ListValue, 'action', _('Action'));
	o.value('direct',   _('Direct'));
	o.value('block',    _('Block'));
	o.value('outbound', _('Outbound'));
	o.default = 'direct';

	o = s.option(form.ListValue, 'outbound', _('Outbound'));
	o.depends('action', 'outbound');
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		uci.sections('singbox-ui', 'outbound').forEach(function (sec) {
			this.value(sec['.name'], sec['.name']);
		}.bind(this));
		return form.ListValue.prototype.load.apply(this, arguments);
	};

	return m;
}

function wireTabs(root, headerSelector, paneByTab, defaultTab) {
	var headerLis = root.querySelectorAll(headerSelector + ' > li');
	function activate(tab) {
		headerLis.forEach(function (el) {
			el.classList.remove('cbi-tab', 'cbi-tab-disabled');
			el.classList.add(el.getAttribute('data-tab') === tab ? 'cbi-tab' : 'cbi-tab-disabled');
		});
		Object.keys(paneByTab).forEach(function (k) {
			paneByTab[k].style.display = (k === tab) ? '' : 'none';
		});
	}
	headerLis.forEach(function (el) {
		el.addEventListener('click', function () { activate(el.getAttribute('data-tab')); });
	});
	activate(defaultTab);
}

function notify(promise, okLabel, errPrefix) {
	return promise.then(function (res) {
		if (res && res.status === 'ok') {
			ui.addNotification(null, E('p', _(okLabel)), 'info');
		} else {
			var msg = (res && res.message) || _('unknown error');
			ui.addNotification(null, E('p', errPrefix + ': ' + msg), 'danger');
		}
		return res;
	}, function (err) {
		ui.addNotification(null, E('p', errPrefix + ': ' + (err.message || err)), 'danger');
	});
}

function renderActionBar() {
	function btn(label, handler) {
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, handler)
		}, _(label));
	}
	return E('div', { 'class': 'sb-actionbar', 'style': 'display:flex;gap:.5em;margin:.5em 0' }, [
		btn(_('Refresh subscriptions'), function () {
			return notify(callRefresh('subscriptions'), 'Done', _('Refresh subscriptions failed'));
		}),
		btn(_('Refresh rule-sets'), function () {
			return notify(callRefresh('rulesets'),      'Done', _('Refresh rule-sets failed'));
		}),
		btn(_('Restart service'), function () {
			return notify(callRestart(),                'Done', _('Restart failed'));
		}),
		btn(_('Preview generated config'), function () {
			return callReadConfig().then(function (res) {
				if (!res || res.status !== 'ok') {
					ui.addNotification(null, E('p', (res && res.message) || _('not generated')), 'danger');
					return;
				}
				ui.showModal(_('Preview generated config'), [
					E('pre', { 'style': 'max-height:60vh;overflow:auto;font-family:monospace' }, res.content),
					E('div', { 'class': 'right' }, [
						E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Close'))
					])
				]);
			});
		})
	]);
}

function renderStatusPanel(holder) {
	function fmtAgo(mt) {
		if (!mt) return _('never');
		var ago = Math.floor(Date.now() / 1000) - mt;
		if (ago < 60)    return ago + 's';
		if (ago < 3600)  return Math.floor(ago / 60)   + 'm';
		if (ago < 86400) return Math.floor(ago / 3600) + 'h';
		return Math.floor(ago / 86400) + 'd';
	}

	callStatus().then(function (res) {
		if (!res || res.status !== 'ok') {
			holder.innerHTML = '';
			holder.appendChild(E('em', _('Status unavailable')));
			return;
		}
		var rows = [];
		rows.push(E('div', {}, [
			E('strong', _('Status') + ': '),
			E('span', { 'style': 'color:' + (res.running ? '#2e7d32' : '#c62828') },
			  res.running ? _('Service running') : _('Service stopped'))
		]));
		function entryList(label, items) {
			if (!items || !items.length) return null;
			return E('div', {}, [
				E('strong', label + ': '),
				items.map(function (it) {
					return it.name + ' (' + fmtAgo(it.mtime) + ')';
				}).join(', ')
			]);
		}
		var sub = entryList(_('Subscriptions'), res.subscriptions);
		if (sub) rows.push(sub);
		var rs = entryList(_('Rule-Sets'), res.rulesets);
		if (rs) rows.push(rs);

		holder.innerHTML = '';
		rows.forEach(function (r) { holder.appendChild(r); });
	});
}

return view.extend({
	load: function () { return uci.load('singbox-ui'); },

	render: function () {
		var self = this;
		var mInput        = buildInputMap();
		var mOutbounds    = buildOutboundsMap();
		var mRulesets     = buildRulesetsMap();
		var mRouteRules   = buildRouteRulesMap();
		var mRouteDefault = buildRouteDefaultMap();

		self._maps = [ mInput, mOutbounds, mRulesets, mRouteRules, mRouteDefault ];

		return Promise.all(self._maps.map(function (m) { return m.render(); }))
		.then(function (nodes) {
			var inputNode      = nodes[0];
			var outboundsNode  = nodes[1];
			var rulesetsNode   = nodes[2];
			var routerulesNode = nodes[3];
			var routedefNode   = nodes[4];

			var actionBar    = renderActionBar();
			var statusHolder = E('div', { 'class': 'sb-status', 'style': 'margin:.5em 0;padding:.5em;border:1px solid #ddd;border-radius:4px' });

			var outputWrap = E('div', {}, [
				E('ul', { 'class': 'cbi-tabmenu sb-subtab-header' }, [
					E('li', { 'data-tab': 'outbounds'  }, _('Outbounds')),
					E('li', { 'data-tab': 'rulesets'   }, _('Rule-Sets')),
					E('li', { 'data-tab': 'routerules' }, _('Route Rules')),
					E('li', { 'data-tab': 'routedef'   }, _('Default'))
				]),
				outboundsNode,
				rulesetsNode,
				routerulesNode,
				routedefNode
			]);

			var root = E('div', {}, [
				actionBar,
				statusHolder,
				E('ul', { 'class': 'cbi-tabmenu sb-tab-header' }, [
					E('li', { 'data-tab': 'input'  }, _('Input')),
					E('li', { 'data-tab': 'output' }, _('Output'))
				]),
				inputNode,
				outputWrap
			]);

			setTimeout(function () {
				wireTabs(root, '.sb-subtab-header', {
					outbounds:  outboundsNode,
					rulesets:   rulesetsNode,
					routerules: routerulesNode,
					routedef:   routedefNode
				}, 'outbounds');
				wireTabs(root, '.sb-tab-header', {
					input:  inputNode,
					output: outputWrap
				}, 'input');
				renderStatusPanel(statusHolder);
			}, 0);

			return root;
		});
	},

	handleSave: function (ev) {
		return Promise.all(this._maps.map(function (m) {
			return m.parse().then(function () { return m.save(); });
		}));
	},

	handleSaveApply: function (ev, mode) {
		return this.handleSave(ev, true).then(function () {
			return ui.changes.apply(mode == 'force-apply');
		});
	},

	handleReset: null
});
