'use strict';
'require ui';
'require uci';
'require rpc';
'require view.singbox-ui.lib.view_state as SbViewState';

var callSubscriptionExpand = rpc.declare({
	object: 'singbox-ui',
	method: 'subscription_expand',
	params: ['name'],
});

// Promise<{<sid>: {endpoints: [...]}}>
function loadAllExpansions() {
	var jobs = uci.sections('singbox-ui', 'outbound')
		.filter(function (s) { return s.type === 'subscription' && s.enabled !== '0'; })
		.map(function (s) {
			var sid = s['.name'];
			return L.resolveDefault(callSubscriptionExpand(sid), null).then(function (r) {
				return [sid, (r && r.status === 'ok') ? r : null];
			});
		});
	return Promise.all(jobs).then(function (pairs) {
		var out = {};
		pairs.forEach(function (p) { if (p[1]) out[p[0]] = p[1]; });
		return out;
	});
}

function fieldLabel(name) {
	return name.charAt(0).toUpperCase() + name.slice(1).replace(/_/g, ' ');
}

function openViewModal(endpoint) {
	var schema = ((SbViewState.getSchema() || {}).outbound || {})[endpoint.type];
	var rows;
	if (schema && Array.isArray(schema.fields)) {
		rows = schema.fields.map(function (f) {
			var v = (endpoint.fields && endpoint.fields[f.name]);
			if (v === undefined || v === null || v === '') v = '—';
			return E('tr', {}, [
				E('th', { 'style': 'text-align:left;padding-right:1em;white-space:nowrap;' }, _(f.ui_label || fieldLabel(f.name))),
				E('td', {}, String(v))
			]);
		});
	} else {
		// Fallback: dump endpoint.fields verbatim.
		rows = Object.keys(endpoint.fields || {}).map(function (k) {
			return E('tr', {}, [ E('th', {}, k), E('td', {}, String(endpoint.fields[k])) ]);
		});
	}
	ui.showModal(_('Subscription endpoint — read-only'), [
		E('p', { 'class': 'cbi-section-descr' }, _('Endpoint expanded from a subscription. Edit the subscription URL itself if you need changes.')),
		E('table', { 'class': 'cbi-section-table' }, [ E('tbody', {}, rows) ]),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, _('Close'))
		])
	]);
}

function injectChildRows(outboundsNode, cache) {
	if (!outboundsNode) return;
	var tbody = outboundsNode.querySelector('.cbi-section-table-tbody, table tbody');
	if (!tbody) return;
	// Strip any prior child rows so refresh doesn't double-insert.
	Array.from(tbody.querySelectorAll('tr.sb-sub-child')).forEach(function (r) { r.remove(); });
	Array.from(tbody.querySelectorAll('tr[data-sid]')).forEach(function (tr) {
		var sid = tr.getAttribute('data-sid');
		var stype = uci.get('singbox-ui', sid, 'type');
		if (stype !== 'subscription') return;
		var entry = cache[sid];
		if (!entry || !Array.isArray(entry.endpoints)) return;
		entry.endpoints.forEach(function (ep, idx) {
			var label = ep.tag || ('item ' + (idx + 1));
			var addr = (ep.server || '') + (ep.server_port ? ':' + ep.server_port : '');
			var child = E('tr', { 'class': 'sb-sub-child', 'data-parent-sid': sid }, [
				E('td', {}, ''),
				E('td', { 'class': 'sb-sub-child-name' }, label),
				E('td', {}, ep.type || ''),
				E('td', {}, addr || '—'),
				E('td', {}, ''),
				E('td', {}, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function () { openViewModal(ep); return false; }
					}, _('View'))
				])
			]);
			tr.parentNode.insertBefore(child, tr.nextSibling);
		});
	});
}

return L.Class.extend({
	loadAllExpansions: loadAllExpansions,
	injectChildRows: injectChildRows,
	openViewModal: openViewModal,
});
