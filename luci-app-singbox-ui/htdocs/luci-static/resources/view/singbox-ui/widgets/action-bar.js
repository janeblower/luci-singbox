'use strict';
'require ui';
'require dom';
'require view.singbox-ui.lib.rpc as SbRpc';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.widgets.status-panel as SbStatusPanel';

var callRefresh    = SbRpc.callRefresh;
var callRestart    = SbRpc.callRestart;
var callReadConfig = SbRpc.callReadConfig;
var callPreviewConfig = SbRpc.callPreviewConfig;
var notify         = SbCommon.notify;
var showJsonModal  = SbCommon.showJsonModal;
var withBusy       = SbCommon.withBusy;
var renderStatusPanel = SbStatusPanel.renderStatusPanel;


function renderActionBar(statusHolder) {
	function refreshStatus() { renderStatusPanel(statusHolder); }
	// btn(label, handler)            — back-compat 2-arg form (no busy label).
	// btn(label, busyLabel, handler) — 3-arg form swaps the button text and
	//   adds the .busy class for the duration of the RPC (C2.2.5).
	function btn(label, busyOrHandler, maybeHandler) {
		var handler, busyLabel;
		if (typeof busyOrHandler === 'function') {
			handler   = busyOrHandler;
			busyLabel = null;
		} else {
			busyLabel = busyOrHandler;
			handler   = maybeHandler;
		}
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function (ev) {
				var self = this;
				return withBusy(ev.currentTarget, busyLabel, function () {
					return Promise.resolve(handler.call(self)).then(refreshStatus);
				});
			})
		}, _(label));
	}
	return E('div', { 'class': 'sb-actionbar', 'style': 'display:flex;gap:.5em;margin:.5em 0' }, [
		btn(_('Refresh subscriptions'), _('Refreshing…'), function () {
			return notify(callRefresh('subscriptions'), 'Done', _('Refresh subscriptions failed'));
		}),
		btn(_('Refresh rule-sets'), _('Refreshing…'), function () {
			return notify(callRefresh('rulesets'),      'Done', _('Refresh rule-sets failed'));
		}),
		btn(_('Restart service'), _('Restarting…'), function () {
			return notify(callRestart(),                'Done', _('Restart failed'));
		}),
		// Preview generated config — show /etc/sing-box/config.json (the LAST
		// applied config). Both Preview buttons now route through showJsonModal
		// with the same {error|json} shape so the error path looks identical
		// (C2.2.4).
		btn(_('Preview generated config'), _('Loading…'), function () {
			var p = callReadConfig().then(function (res) {
				if (!res || res.status !== 'ok')
					return { error: (res && res.message) || _('not generated') };
				return { json: res.content };
			}, function (err) {
				return { error: (err && err.message) ? err.message : String(err) };
			});
			showJsonModal(_('Preview generated config'), p);
		}),
		// Dry-run preview — calls preview_config which regenerates the JSON
		// from the CURRENT UCI state into a tmpfile without touching
		// /etc/sing-box, nftables, or the running service. Useful for
		// reviewing a draft before pressing "Save & Apply".
		btn(_('Preview config'), _('Generating…'), function () {
			var p = callPreviewConfig().then(function (res) {
				if (!res || res.status !== 'ok')
					return { error: (res && res.message) || _('preview failed') };
				return { json: res.content };
			}, function (err) {
				return { error: (err && err.message) ? err.message : String(err) };
			});
			showJsonModal(_('Preview config (dry-run)'), p);
		}),
	]);
}

return L.Class.extend({ renderActionBar: renderActionBar });
