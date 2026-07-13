'use strict';
'require form';
'require uci';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

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

// Every UCI option that holds a reference to a section BY NAME, grouped by the
// kind of section being pointed at. A rename that doesn't rewrite these leaves a
// dangling reference, which the backend then silently drops with a warn() —
// route.uc: "outbound '<old>' is not a defined outbound; dropping". Entries are
// [sectiontype, option, isList].
var RENAME_REFS = {
	outbound: [
		['route_rule',    'outbound',         false],
		['route_default', 'outbound',         false],
		['outbound',      'group_outbounds',  true ],
		['outbound',      'group_default',    false],
		['outbound',      'detour',           false],
		['dns_server',    'detour',           false],
		['ruleset',       'download_detour',  false],
	],
	ruleset: [
		['route_rule', 'rule_set', true],
		['dns_rule',   'rule_set', true],
	],
	route_rule: [
		['route_rule', 'rules', true],
		['ruleset',    'rules', true],
	],
	dns_rule: [
		['dns_rule', 'rules', true],
	],
	dns_server: [
		['dns',      'final',            false],
		['dns',      'default_resolver', false],
		['dns_rule', 'server',           false],
	],
};

// renameRefs(kind, oldName, newName) — rewrite every reference to oldName in the
// uci changeset. Call BEFORE uci.rename() so the sections are still addressable
// by their current ids. UCI section names are unique across the whole package
// (not per-type), so no cross-kind name can be hit by accident.
function renameRefs(kind, oldName, newName) {
	(RENAME_REFS[kind] || []).forEach(function (ref) {
		var stype = ref[0], opt = ref[1], isList = ref[2];
		(uci.sections('singbox-ui', stype) || []).forEach(function (sec) {
			var v = sec[opt];
			if (v == null) return;
			if (isList) {
				var arr = Array.isArray(v) ? v : [v];
				if (arr.indexOf(oldName) < 0) return;
				uci.set('singbox-ui', sec['.name'], opt, arr.map(function (n) {
					return (n === oldName) ? newName : n;
				}));
			} else if (v === oldName) {
				uci.set('singbox-ui', sec['.name'], opt, newName);
			}
		});
	});
}

// addRenameField(s, tab) — the section-name editor. `tab` is REQUIRED for a
// tabbed section: LuCI only renders options that carry a tab, so the untabbed
// s.option() form never showed up in the modal at all (same trap tabs/dns.js
// documents for enabled/type). Declare it right after s.tab() and before any
// other taboption so "Name" lands first in the pane.
function addRenameField(s, tab) {
	var o = tab
		? s.taboption(tab, form.Value, '__rename', _('Name'))
		: s.option(form.Value, '__rename', _('Name'));
	o.modalonly = true;
	o.rmempty   = false;
	o.datatype  = 'and(minlength(1), uciname)';
	o.cfgvalue  = function (section_id) { return section_id; };
	// Reject duplicate names. UCI section names live in ONE namespace per config
	// file, so an outbound may not take a dns_server's name either — checking
	// only same-kind siblings let a cross-kind collision through (spec C2.2.12).
	o.validate = function (section_id, value) {
		if (!value) return _('Name must not be empty');
		if (value === section_id) return true;
		if (uci.get('singbox-ui', value) != null)
			return _('Name already in use');
		return true;
	};
	o.write     = function (section_id, value) {
		if (!value || value === section_id) return;
		renameRefs(s.sectiontype, section_id, value);
		uci.rename('singbox-ui', section_id, value);
	};
	o.remove = function () {};
}

// Package-owned sections carry `builtin '1'`: the built-in rule-sets
// (uci-defaults/92-singbox-ui-rulesets) and the built-in `wan` outbound. The
// package owns their name and their settings, so the grid refuses to edit or
// delete them — but `enabled` stays a normal per-row toggle, which is the whole
// point of shipping the rule-sets.
function isBuiltin(sid) { return uci.get('singbox-ui', sid, 'builtin') === '1'; }

// lockBuiltinRow(s, note, hideFn) — make every builtin row of a GridSection
// read-only. `disabled` is what greys the buttons out, so no extra CSS is needed
// for that; .sb-builtin-row only carries the row tint. `hideFn` is optional and
// filters the rows away entirely (the rule-sets' master switch uses it).
//
// LuCI hands renderRowActions the <tr> it is building (form.js
// renderRowActions(section_id, more_label, trEl)), which is what lets one hook
// both disable the buttons and tag the row.
function lockBuiltinRow(s, note, hideFn) {
	if (typeof hideFn === 'function') {
		var origFilter = s.filter;
		s.filter = function (section_id) {
			if (isBuiltin(section_id) && hideFn()) return false;
			return origFilter ? origFilter.apply(this, arguments) : true;
		};
	}

	var origRowActions = s.renderRowActions;
	s.renderRowActions = function (section_id, more_label, trEl) {
		var td = origRowActions.apply(this, arguments);
		if (!isBuiltin(section_id)) return td;
		if (trEl && trEl.classList) trEl.classList.add('sb-builtin-row');
		if (td && td.querySelectorAll)
			td.querySelectorAll('button').forEach(function (b) {
				// The drag handle only reorders; it mutates nothing the package owns.
				if (b.classList && b.classList.contains('drag-handle')) return;
				b.disabled = true;
				b.title = note;
			});
		return td;
	};
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

// compareVersions('1.13.0','1.12.5') -> 1 ; equal -> 0 ; older -> -1.
// Empty/unknown either side -> 0 (fail open: never gate when version unknown).
function compareVersions(a, b) {
	if (!a || !b) return 0;
	// Strip build/pre-release suffixes (everything after the first - or +) so
	// e.g. '1.14.0-rc1' compares as '1.14.0'; compare ALL components, not just 3.
	var pa = String(a).split(/[-+]/)[0].split('.');
	var pb = String(b).split(/[-+]/)[0].split('.');
	var n = Math.max(pa.length, pb.length);
	for (var i = 0; i < n; i++) {
		var na = parseInt(pa[i] || '0', 10), nb = parseInt(pb[i] || '0', 10);
		if (isNaN(na)) na = 0;
		if (isNaN(nb)) nb = 0;
		if (na > nb) return 1;
		if (na < nb) return -1;
	}
	return 0;
}

// applyVersionGate(o, schemaByType, coreVersion, compatOnly): for each <option>
// whose type is out of the [min_version, max_version) window relative to
// coreVersion: when compatOnly is OFF, disable it + suffix the label with
// " (requires X.Y+)" or " (removed in X.Y)"; when ON, remove the option.
function applyVersionGate(o, schemaByType, coreVersion, compatOnly) {
	var gated = {};   // value -> note string
	Object.keys(schemaByType || {}).forEach(function (k) {
		var e = schemaByType[k] || {};
		if (e.min_version && compareVersions(coreVersion, e.min_version) < 0)
			gated[k] = '(' + _('requires') + ' ' + e.min_version.split('.').slice(0, 2).join('.') + '+)';
		else if (e.max_version && compareVersions(coreVersion, e.max_version) >= 0)
			gated[k] = '(' + _('removed in') + ' ' + e.max_version.split('.').slice(0, 2).join('.') + ')';
	});
	var origRender = o.renderWidget;
	o.renderWidget = function (section_id, option_index, cfgvalue) {
		var node = origRender.call(this, section_id, option_index, cfgvalue);
		var sel = (node.tagName === 'SELECT') ? node
			: (node.querySelector && node.querySelector('select'));
		if (sel) {
			var opts = Array.prototype.slice.call(sel.options);
			opts.forEach(function (opt) {
				if (!gated[opt.value]) return;
				if (compatOnly) { if (opt.parentNode) opt.parentNode.removeChild(opt); return; }
				opt.disabled = true;
				if (opt.textContent.indexOf(gated[opt.value]) < 0)
					opt.textContent += ' ' + gated[opt.value];
			});
		}
		return node;
	};
	o.validate = function (_section_id, value) {
		if (gated[value]) return _('Incompatible with installed sing-box') + ' ' + gated[value];
		return true;
	};
}

function notify(promise, okLabel, errPrefix) {
	return promise.then(function (res) {
		if (res && res.status === 'ok') {
			ui.addNotification(null, E('p', _(okLabel)), 'info');
		} else {
			var msg = (res && res.message) || _('unknown error');
			ui.addNotification(null, E('p', errPrefix + ': ' + msg), 'error');
		}
		return res;
	}, function (err) {
		// err may be null/undefined (e.g. an aborted RPC), so guard before
		// reading .message — otherwise the error handler itself TypeErrors and
		// the rejection becomes uncaught (spec S2-7).
		var msg = (err && err.message) || err || _('unknown error');
		ui.addNotification(null, E('p', errPrefix + ': ' + msg), 'error');
	});
}

// logicalSubRuleValidate(uci, _) — shared validate fn for a logical rule's
// sub-rule list. route_rule and dns_rule both reference default-typed sub-rules
// by name; reject self-reference and any sub-rule whose UCI type !== 'default'.
// Factored here so the Route and DNS tabs can't drift (code review #8).
function logicalSubRuleValidate(uci, _) {
	return function (section_id, value) {
		var vals = (value == null) ? [] : (Array.isArray(value) ? value : [value]);
		for (var i = 0; i < vals.length; i++) {
			var n = vals[i];
			if (!n) continue;
			if (n === section_id) return _('A logical rule cannot reference itself.');
			var t = uci.get('singbox-ui', n, 'type') || 'default';
			if (t !== 'default') return _('Sub-rules must be Default rules: ') + n;
		}
		return true;
	};
}

// waitSubRefresh(onTick) — an async refresh returns the moment the fetch is
// FORKED, so the caller is not done until the backend's progress side-car says
// so. Polls sub_status; onTick(res) gets every reply (the dashboard repaints,
// the action bar counts "3/5"). MAX_TICKS is the backstop for a child that dies
// without ever clearing running:1 — otherwise the button spins forever.
function waitSubRefresh(onTick) {
    var INTERVAL = 1500, MAX_TICKS = 200;   // ~5 min ceiling
    var tries = 0;
    function tick() {
        return SbRpc.callSubStatus().then(function (res) {
            if (onTick) onTick(res);
            var p = res && res.progress;
            if (!p || !p.running || ++tries > MAX_TICKS) return res;
            return new Promise(function (resolve) {
                window.setTimeout(resolve, INTERVAL);
            }).then(tick);
        });
    }
    return tick();
}

return L.Class.extend({
    loadOutboundList:  loadOutboundList,
    waitSubRefresh:    waitSubRefresh,
    addRenameField:    addRenameField,
    renameRefs:        renameRefs,
    isBuiltin:         isBuiltin,
    lockBuiltinRow:    lockBuiltinRow,
    wireTabs:          wireTabs,
    notify:            notify,
    showJsonModal:     showJsonModal,
    copyToClipboard:   copyToClipboard,
    withBusy:          withBusy,
    compareVersions:   compareVersions,
    applyVersionGate:  applyVersionGate,
    logicalSubRuleValidate: logicalSubRuleValidate,
});
