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

// showJsonModal(title, contentPromise) — generic modal that displays a JSON
// string in a <pre> with a Copy button. `contentPromise` resolves to either
// the string to display or to { error: "<message>" } to render an error.
// Used by importers/inbound.js (export_section) and widgets/action-bar.js
// (preview_config) — keep the markup/behaviour consistent.
function showJsonModal(title, contentPromise) {
	var pre = E('pre', {
		'class': 'cbi-input-textarea',
		'style': 'max-height:50vh;overflow:auto;white-space:pre-wrap;' +
		         'font-family:monospace;font-size:90%;'
	}, _('Loading…'));
	var status = E('div', { 'style': 'margin-top:8px;color:#555;font-size:90%;' });

	function showCopyResult(msg, isErr) {
		status.textContent = msg;
		status.style.color = isErr ? '#c33' : '#3a3';
	}

	function fallbackCopy(txt) {
		try {
			var ta = E('textarea', {
				'style': 'position:fixed;top:-1000px;left:-1000px;width:1px;height:1px;'
			});
			ta.value = txt;
			document.body.appendChild(ta);
			ta.focus(); ta.select();
			var ok = false;
			try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
			document.body.removeChild(ta);
			if (ok) showCopyResult(_('Copied to clipboard.'), false);
			else showCopyResult(_('Copy failed — select the text and copy manually.'), true);
		} catch (e) {
			showCopyResult(_('Copy failed — select the text and copy manually.'), true);
		}
	}

	function copyToClipboard() {
		var txt = pre.textContent || '';
		if (window.navigator && window.navigator.clipboard
		    && typeof window.navigator.clipboard.writeText === 'function') {
			window.navigator.clipboard.writeText(txt).then(function () {
				showCopyResult(_('Copied to clipboard.'), false);
			}, function () {
				fallbackCopy(txt);
			});
		} else {
			fallbackCopy(txt);
		}
	}

	ui.showModal(title, [
		pre, status,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')),
			' ',
			E('button', { 'class': 'cbi-button cbi-button-action', 'click': copyToClipboard },
				_('Copy'))
		])
	]);

	Promise.resolve(contentPromise).then(function (res) {
		if (res && typeof res === 'object' && res.error != null) {
			pre.textContent = _('Error: ') + res.error;
			return;
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
});
