'use strict';
'require form';
'require uci';
'require ui';

function loadOutboundList(o, includeNone) {
	o.load = function (section_id) {
		this.keylist = [];
		this.vallist = [];
		if (includeNone) this.value('', _('(none)'));
		var self = this;
		uci.sections('singbox-ui', 'outbound')
			.map(function (sec) { return sec['.name']; })
			.sort()
			.forEach(function (n) { self.value(n, n); });
		return form.ListValue.prototype.load.apply(this, arguments);
	};
}

function addRenameField(s) {
	var o = s.option(form.Value, '__rename', _('Name'));
	o.modalonly = true;
	o.rmempty   = false;
	o.datatype  = 'and(minlength(1), uciname)';
	o.cfgvalue  = function (section_id) { return section_id; };
	// Reject duplicate names within the same section kind — sing-box
	// section ids must be unique and the rename silently collides
	// otherwise (spec C2.2.12).
	o.validate = function (section_id, value) {
		if (!value) return _('Name must not be empty');
		if (value === section_id) return true;
		var kind = s.sectiontype;
		var siblings = uci.sections('singbox-ui', kind) || [];
		for (var i = 0; i < siblings.length; i++) {
			var name = siblings[i] && siblings[i]['.name'];
			if (name === value && name !== section_id)
				return _('Name already in use by another') + ' ' + kind;
		}
		return true;
	};
	o.write     = function (section_id, value) {
		if (value && value !== section_id)
			uci.rename('singbox-ui', section_id, value);
	};
	o.remove = function () {};
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

// fallbackCopy / copyToClipboard — extracted to file scope so importers and
// widgets share one implementation (C2.2.6). `text` is the literal string to
// place on the clipboard. `onResult(msg, isErr)` is an optional callback used
// by callers that show a small "Copied." / "Copy failed." status string.
function fallbackCopy(text, onResult) {
	try {
		var ta = E('textarea', {
			'style': 'position:fixed;top:-1000px;left:-1000px;width:1px;height:1px;'
		});
		ta.value = text;
		document.body.appendChild(ta);
		ta.focus(); ta.select();
		var ok = false;
		try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
		document.body.removeChild(ta);
		if (onResult) {
			if (ok) onResult(_('Copied to clipboard.'), false);
			else onResult(_('Copy failed — select the text and copy manually.'), true);
		}
	} catch (e) {
		if (onResult) onResult(_('Copy failed — select the text and copy manually.'), true);
	}
}

function copyToClipboard(text, onResult) {
	if (window.navigator && window.navigator.clipboard
	    && typeof window.navigator.clipboard.writeText === 'function') {
		window.navigator.clipboard.writeText(text).then(function () {
			if (onResult) onResult(_('Copied to clipboard.'), false);
		}, function () {
			fallbackCopy(text, onResult);
		});
	} else {
		fallbackCopy(text, onResult);
	}
}

// withBusy(btn, busyLabel, fn) — flips a button into a disabled "busy" state
// for the duration of fn(). Used by widgets/action-bar.js to give visible
// feedback during long RPCs like Refresh subscriptions (C2.2.5).
function withBusy(btn, busyLabel, fn) {
	if (!btn || !btn.classList) return Promise.resolve().then(fn);
	btn.classList.add('busy');
	btn.disabled = true;
	var prevText = btn.textContent;
	if (busyLabel) btn.textContent = busyLabel;
	function restore() {
		btn.classList.remove('busy');
		btn.disabled = false;
		btn.textContent = prevText;
	}
	return Promise.resolve().then(fn).then(function (r) {
		restore();
		return r;
	}, function (e) {
		restore();
		throw e;
	});
}

// showJsonModal(title, contentOrPromise) — generic modal that displays a JSON
// string in a <pre> with a Copy button. The second argument may be:
//   * a string (rendered directly),
//   * a Promise resolving to the string,
//   * an object { error: msg }  (renders an error line),
//   * an object { json: str }   (renders the string),
//   * a Promise resolving to one of those object shapes.
// Used by importers/inbound.js (export_section) and widgets/action-bar.js
// (read_config / preview_config) — keep the markup/behaviour consistent.
function showJsonModal(title, contentOrPromise) {
	var pre = E('pre', {
		'class': 'cbi-input-textarea sb-json-modal-pre',
		'style': 'max-height:50vh;overflow:auto;white-space:pre-wrap;' +
		         'font-family:monospace;font-size:90%;'
	}, _('Loading…'));
	var status = E('div', { 'class': 'sb-json-modal-status',
		'style': 'margin-top:8px;color:#555;font-size:90%;' });

	function showCopyResult(msg, isErr) {
		status.textContent = msg;
		// `.sb-error` / `.sb-ok` carry the colour rules from style.css.
		status.classList.remove('sb-error', 'sb-ok');
		status.classList.add(isErr ? 'sb-error' : 'sb-ok');
	}

	function onCopyClick() {
		copyToClipboard(pre.textContent || '', showCopyResult);
	}

	ui.showModal(title, [
		pre, status,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': onCopyClick },
				_('Copy'))
		])
	]);

	Promise.resolve(contentOrPromise).then(function (res) {
		if (res && typeof res === 'object') {
			if (res.error != null) {
				pre.textContent = _('Error: ') + res.error;
				return;
			}
			if (res.json != null) {
				pre.textContent = String(res.json);
				return;
			}
			if (res.content != null) {
				pre.textContent = String(res.content);
				return;
			}
		}
		pre.textContent = (res == null) ? '' : String(res);
	}, function (err) {
		pre.textContent = _('RPC failed: ') + (err && err.message ? err.message : String(err));
	});
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

return L.Class.extend({
    loadOutboundList: loadOutboundList,
    addRenameField:   addRenameField,
    wireTabs:         wireTabs,
    notify:           notify,
    showJsonModal:    showJsonModal,
    copyToClipboard:  copyToClipboard,
    fallbackCopy:     fallbackCopy,
    withBusy:         withBusy,
});
