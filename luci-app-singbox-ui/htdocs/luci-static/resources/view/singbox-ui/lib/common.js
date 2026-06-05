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
});
