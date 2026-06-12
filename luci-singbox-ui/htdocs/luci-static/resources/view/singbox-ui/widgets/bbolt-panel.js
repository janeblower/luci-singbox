'use strict';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

// bbolt-client helper panel for the Rule-Sets tab. The helper is NOT shipped in
// the package — it is downloaded on demand from GitHub Releases (latest) and is
// required to build nft rules from sing-box's cache.db. This panel shows whether
// it is installed and offers a one-click install (rpcd bbolt_install verifies a
// sha256 before writing the binary).
//
// XSS invariant: untrusted text only via E()/.textContent; innerHTML is used
// solely to clear (= '').

var callBboltStatus  = SbRpc.callBboltStatus;
var callBboltInstall = SbRpc.callBboltInstall;

function renderStatus(holder) {
	return callBboltStatus().then(function (res) {
		var el = holder.querySelector('.sb-bbolt-state');
		if (!el) return;
		el.innerHTML = '';
		// Status colour via the shared .sb-ok/.sb-error classes in style.css
		// instead of inline hex, so coloring stays centralized/themeable (audit
		// 9.7).
		if (res && res.installed) {
			el.appendChild(E('span', { 'class': 'sb-ok' },
				_('installed') + (res.arch ? ' (' + res.arch + ')' : '')));
		} else {
			el.appendChild(E('span', { 'class': 'sb-error' },
				_('not installed — required to build nft rules from cache')));
		}
	}).catch(function () {
		var el = holder.querySelector('.sb-bbolt-state');
		if (el) { el.innerHTML = ''; el.appendChild(E('em', _('status unavailable'))); }
	});
}

function renderBboltPanel(holder) {
	holder.innerHTML = '';
	var btn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function () {
			return callBboltInstall().then(function (r) {
				if (r && r.installed)
					ui.addNotification(null, E('p', _('bbolt-client installed')), 'info');
				else
					ui.addNotification(null,
						E('p', (r && r.message) ? r.message : _('bbolt-client install failed')),
						'error');
				return renderStatus(holder);
			}).catch(function () {
				ui.addNotification(null, E('p', _('bbolt-client install failed')), 'error');
			});
		})
	}, _('Download bbolt-client'));

	holder.appendChild(E('div', { 'class': 'cbi-value' }, [
		E('label', { 'class': 'cbi-value-title' }, _('bbolt-client helper')),
		E('div', { 'class': 'cbi-value-field' }, [
			E('span', { 'class': 'sb-bbolt-state' }, _('checking…')),
			E('span', { 'style': 'margin-left:1em' }, btn)
		])
	]));
	return renderStatus(holder);
}

return L.Class.extend({ renderBboltPanel: renderBboltPanel });
