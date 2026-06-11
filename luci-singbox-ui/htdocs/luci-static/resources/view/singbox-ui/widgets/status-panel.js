'use strict';
'require view.singbox-ui.lib.rpc as SbRpc';

var callStatus = SbRpc.callStatus;

function renderStatusPanel(holder) {
	// Use the server-supplied `now` so 'X ago' stays accurate even when the
	// browser clock has drifted from the router (common on routers without NTP).
	function fmtAgo(now, mt) {
		if (!mt) return _('never');
		var ago = Math.max(0, now - mt);
		if (ago < 60)    return ago + 's';
		if (ago < 3600)  return Math.floor(ago / 60)   + 'm';
		if (ago < 86400) return Math.floor(ago / 3600) + 'h';
		return Math.floor(ago / 86400) + 'd';
	}

	return callStatus().then(function (res) {
		holder.innerHTML = '';
		if (!res || res.status !== 'ok') {
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
					return it.name + ' (' + fmtAgo(res.now, it.mtime) + ')';
				}).join(', ')
			]);
		}
		var sub = entryList(_('Subscriptions'), res.subscriptions);
		if (sub) rows.push(sub);
		var rs = entryList(_('Rule-Sets'), res.rulesets);
		if (rs) rows.push(rs);

		rows.forEach(function (r) { holder.appendChild(r); });
	// callStatus rejecting (rpcd restart / ubus error) must not leak an
	// uncaught rejection; render the same 'unavailable' fallback (spec S2-1).
	}).catch(function () {
		holder.innerHTML = '';
		holder.appendChild(E('em', _('Status unavailable')));
	});
}

return L.Class.extend({ renderStatusPanel: renderStatusPanel });
