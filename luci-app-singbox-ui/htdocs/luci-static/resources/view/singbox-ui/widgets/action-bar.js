'use strict';
'require ui';
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
var waitSubRefresh = SbCommon.waitSubRefresh;
var renderStatusPanel = SbStatusPanel.renderStatusPanel;


function renderActionBar(statusHolder) {
	function refreshStatus() { renderStatusPanel(statusHolder); }
	// btn(label, busyLabel, handler) — swaps the button text and adds the .busy
	// class for the duration of the RPC (C2.2.5). (The 2-arg back-compat form is
	// gone: all five call sites pass three arguments.)
	function btn(label, busyLabel, handler) {
		return E('button', {
			'class': 'btn cbi-button cbi-button-action',
			'click': ui.createHandlerFn(this, function (ev) {
				var self = this;
				var el = ev.currentTarget;
				return withBusy(el, busyLabel, function () {
					// The element is handed to the handler so a long-running job can
					// keep the label live ("Refreshing… 3/5"); withBusy restores the
					// original text on both settle paths, so this is safe to mutate.
					return Promise.resolve(handler.call(self, el)).then(refreshStatus);
				});
			})
		}, label);   // label (and busyLabel) are already _()-translated by the
		             // caller; translating again here double-handles the msgid
		             // and pollutes .pot extraction.
	}
	return E('div', { 'class': 'sb-actionbar', 'style': 'display:flex;gap:.5em;margin:.5em 0' }, [
		btn(_('Refresh subscriptions'), _('Refreshing…'), function (el) {
			// async: the fetch is forked and we poll its progress side-car. A
			// synchronous refresh of several subscriptions outlives the ubus
			// timeout, which surfaced as "Refresh failed" over a fetch that was
			// in fact still running (and then succeeded, invisibly).
			var p = callRefresh('subscriptions', '', true).then(function () {
				return waitSubRefresh(function (res) {
					var pr = res && res.progress;
					if (pr && pr.running && pr.total > 0)
						el.textContent = _('Refreshing… %d/%d').format(pr.done, pr.total);
				});
			});
			return notify(p, 'Done', _('Refresh subscriptions failed'));
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
