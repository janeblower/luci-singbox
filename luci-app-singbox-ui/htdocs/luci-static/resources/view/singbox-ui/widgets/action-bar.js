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

// ── Reveal-secrets button (D3.6) ─────────────────────────────────────────────
// The container node lives at module scope so the timer can repaint it without
// holding a reference to the enclosing renderActionBar call.
var revealBtnContainer = E('span', { 'data-singbox-ui-reveal': '1' });
var revealTimer = null;

function revealBtnLabel() {
	var t = window.singboxUiRevealToken;
	if (!t) return _('Show secrets');
	var remaining = Math.max(0, t.expires_ts - Math.floor(Date.now() / 1000));
	var m = Math.floor(remaining / 60);
	var s = remaining % 60;
	return _('Hide secrets (%d:%02d)').format(m, s);
}

function repaintRevealBtn() {
	dom.content(revealBtnContainer, E('button', {
		'class': 'btn cbi-button cbi-button-neutral',
		'click': onRevealClick,
	}, revealBtnLabel()));
}

function stopRevealTimer() {
	if (revealTimer) { clearInterval(revealTimer); revealTimer = null; }
}

function startRevealTimer() {
	stopRevealTimer();
	revealTimer = setInterval(function () {
		var t = window.singboxUiRevealToken;
		if (!t) { stopRevealTimer(); repaintRevealBtn(); return; }
		if (Math.floor(Date.now() / 1000) >= t.expires_ts) {
			window.singboxUiRevealToken = null;
			stopRevealTimer();
		}
		repaintRevealBtn();
	}, 1000);
}

function doGrant() {
	ui.hideModal();
	return SbRpc.revealGrant().then(function (r) {
		if (r && r.status === 'ok') {
			window.singboxUiRevealToken = { token: r.token, expires_ts: r.expires_ts };
			startRevealTimer();
			repaintRevealBtn();
		}
	});
}

function onRevealClick(/*ev*/) {
	if (window.singboxUiRevealToken) {
		return SbRpc.revealRevoke().then(function () {
			window.singboxUiRevealToken = null;
			stopRevealTimer();
			repaintRevealBtn();
		});
	}
	return ui.showModal(_('Reveal secrets?'), [
		E('p', {}, _('You are about to reveal credentials. They will be visible to anyone with read access to this LuCI install for the next 5 minutes.')),
		E('div', { 'class': 'right' }, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.hideModal }, _('Cancel')),
			' ',
			E('button', { 'class': 'btn cbi-button cbi-button-action', 'click': doGrant }, _('Reveal')),
		]),
	]);
}

// Render the initial button state (idle = no token).
repaintRevealBtn();
// ─────────────────────────────────────────────────────────────────────────────

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
			var p = callReadConfig(SbRpc.withRevealToken({}).token).then(function (res) {
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
			var p = callPreviewConfig(SbRpc.withRevealToken({}).token).then(function (res) {
				if (!res || res.status !== 'ok')
					return { error: (res && res.message) || _('preview failed') };
				return { json: res.content };
			}, function (err) {
				return { error: (err && err.message) ? err.message : String(err) };
			});
			showJsonModal(_('Preview config (dry-run)'), p);
		}),
		// Show / Hide secrets toggle (D3.6).
		revealBtnContainer,
	]);
}

return L.Class.extend({ renderActionBar: renderActionBar });
