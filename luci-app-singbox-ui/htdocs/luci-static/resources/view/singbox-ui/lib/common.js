'use strict';
'require form';
'require uci';
'require ui';
'require view.singbox-ui.lib.rpc as SbRpc';

// prettyBytes(n) — forkop's byte formatter: decimal (1000) divisor, 3 significant
// digits. One copy so the dashboard and monitoring tab never drift into mixing
// 1000- and 1024-based scales (one of which is always wrong).
function prettyBytes(n) {
	n = +n || 0;
	if (n < 1000) return n + ' B';
	var u = ['B','KB','MB','GB','TB','PB'];
	var e = Math.min(Math.floor(Math.log(n) / Math.log(1000)), u.length - 1);
	return Number((n / Math.pow(1000, e)).toPrecision(3)) + ' ' + u[e];
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
		['clash_api',     'external_ui_download_detour', false],
		// The ONE shared detour every built-in rule-set inherits
		// (ruleset.uc stamps it as download_detour on each builtin that has
		// none). Missing it degraded quietly: ruleset.uc drops the dangling tag
		// with a warn and all 25 built-ins silently stop downloading via proxy.
		['singbox-ui',    'default_ruleset_detour',      false],
	],
	// An inbound's `detour` (shared listen block) names ANOTHER INBOUND. sing-box
	// does not catch a dangling one: `sing-box check` passes, the daemon starts,
	// and the detour just never happens — so a rename that skips this table fails
	// silently and invisibly, worse than the dropped-with-warn cases above.
	inbound: [
		['inbound', 'detour', false],
	],
	ruleset: [
		['route_rule', 'rule_set', true],
		['dns_rule',   'rule_set', true],
		// A tun inbound's route_address_set / route_exclude_address_set name rule-set
		// sections too (Task 5). Before Task 5 a stale tun reference made sing-box
		// refuse the config outright — loud and obvious. Task 5's prune (inbound.uc)
		// now silently drops a reference to a rule-set that no longer exists, which
		// turns a missed rename here into a SILENT full-tunnel: the tun's
		// route_address_set goes empty, and "only these rule-sets enter the tunnel"
		// becomes "everything enters the tunnel". Keeping this table in sync with the
		// rename is what keeps that path loud.
		['inbound',    'route_address_set',         true],
		['inbound',    'route_exclude_address_set', true],
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
		// Nothing validates these three, so a missed rename ships a dangling tag
		// straight into the config and sing-box REJECTS THE WHOLE FILE
		// ("domain_resolver: server not found"). The pre-flight `sing-box check`
		// then cancels the reload, so Apply looks like it simply did nothing.
		// dns.uc only guards dns_rule.server and dns.final; route.uc guards
		// nothing at all.
		['dns_server', 'domain_resolver',  false],
		['dns_server', 'address_resolver', false],
		['route_rule', 'server',           false],
	],
};

// renameRefs(kind, oldName, newName) — rewrite every reference to oldName in the
// uci changeset. Called by renameSection() AFTER the section itself has been
// re-created under the new name, so a self-reference (a group listing itself, a
// logical rule naming a sibling) is rewritten in the copy that survives. UCI
// section names are unique across the whole package (not per-type), so no
// cross-kind name can be hit by accident.
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

// renameSection(oldSid, newName) — rename a section in the uci changeset.
//
// LuCI's uci API has NO rename. Verified against the shipped uci.js: the methods
// are createSID/resolveSID/add/clone/remove/get/set/unset/sections/move — the
// word "rename" appears only in doc comments. `uci.rename('singbox-ui', …)` was
// a plain TypeError on every call, and because renameRefs() ran FIRST every
// by-name reference had already been repointed at a name that then never came
// into existence. The next Save & Apply flushed that: for a rule-set that means
// tun.route_address_set — a WHITELIST — goes empty, i.e. the tunnel silently
// swallows the entire address space.
//
// uci.clone() is not the answer either: it builds the new section from
// state.values alone (staged edits dropped) and returns a createSID(), not a
// name. So: read merged values, add under the new name, copy, remove, put back.
//
// The move() matters. uci.add() appends, and for route_rule/dns_rule the order
// of sections in the file IS the evaluation order — renaming a rule must not
// quietly demote it to the bottom of the chain.
function renameSection(oldSid, newName) {
	var old = uci.get('singbox-ui', oldSid);
	if (!old || !newName || newName === oldSid) return false;

	var vals = {}, k;
	for (k in old) if (Object.prototype.hasOwnProperty.call(old, k) && k.charAt(0) !== '.') vals[k] = old[k];

	// The section that FOLLOWS this one in file order, to move the new one back
	// into place. If there is none, it was last and add() already put it last.
	var all = uci.sections('singbox-ui'), next = null;
	for (var i = 0; i < all.length; i++) {
		if (all[i]['.name'] !== oldSid) continue;
		next = all[i + 1] ? all[i + 1]['.name'] : null;
		break;
	}

	var stype = old['.type'];
	uci.add('singbox-ui', stype, newName);
	Object.keys(vals).forEach(function (opt) { uci.set('singbox-ui', newName, opt, vals[opt]); });
	uci.remove('singbox-ui', oldSid);
	if (next) uci.move('singbox-ui', newName, next, false);

	// AFTER the copy exists, so a self-reference (a group listing itself, a
	// logical rule naming a sibling) is rewritten in the section that survives.
	renameRefs(stype, oldSid, newName);
	return true;
}

// addRenameField(s, tab) — the section-name editor. `tab` is REQUIRED for a
// tabbed section: LuCI only renders options that carry a tab, so the untabbed
// s.option() form never showed up in the modal at all (same trap tabs/dns.js
// documents for enabled/type). Declare it right after s.tab() and before any
// other taboption so "Name" lands first in the pane.
function addRenameField(s, tab) {
	// Filled by write(), applied once the section has finished parsing. The
	// rename CANNOT happen inside write(): LuCI parses options in declaration
	// order and "Name" is declared FIRST, so renaming there would leave every
	// following option writing into a section id that no longer exists —
	// uci.set() on a removed section returns silently, so the rest of the
	// modal's edits would just evaporate.
	var pending = null;

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
	o.write = function (section_id, value) {
		if (!value || value === section_id) return;
		pending = { sid: section_id, name: value };
	};
	o.remove = function () {};

	function armSection(sec) {
		var base = sec.parse;
		sec.parse = function () {
			return Promise.resolve(base.apply(this, arguments)).then(function (r) {
				if (pending) {
					renameSection(pending.sid, pending.name);
					pending = null;
				}
				return r;
			});
		};
	}
	armSection(s);

	// A GridSection renders `modalonly` options in a modal built on a FRESH
	// section instance (cloneOptions copies the options, not the section), so
	// the wrapper above never sees that parse. addModalOptions is the one hook
	// LuCI runs on the modal section before it is rendered.
	var origAddModal = s.addModalOptions;
	s.addModalOptions = function (ms) {
		armSection(ms);
		return origAddModal ? origAddModal.apply(this, arguments) : undefined;
	};
}

// Package-owned sections carry `builtin '1'`: the built-in rule-sets
// (uci-defaults/92-singbox-ui-rulesets) and the built-in `wan` outbound. The
// package owns their name and their settings, so the grid refuses to edit or
// delete them — but `enabled` stays a normal per-row toggle, which is the whole
// point of shipping the rule-sets.
function isBuiltin(sid) { return uci.get('singbox-ui', sid, 'builtin') === '1'; }

// THE frontend mirror of helpers.ruleset_active() / helpers.builtin_rulesets_on().
// ONE place, exactly as the backend keeps ONE predicate — it lived in tabs/route.js
// (the grid) AND in lib/descriptor_form.js (the rule-set picker), and two copies of
// a rule the backend enforces is a disagreement waiting to happen.
//
// The backend PRUNES whatever this rejects (route.uc, dns.uc, nft-rulesets.uc), so
// the picker must offer nothing the backend then throws away: a reference to a
// pruned rule-set is dropped with a warn nobody sees. For tun.route_address_set
// that silent prune INVERTS the tunnel — the field means "ONLY these CIDRs enter
// the tun", so losing every entry makes the tun capture the whole address space.
//
// Unset means ON (NO-migration: an install that predates the option must not
// silently lose its rule-sets); only an explicit "0" turns them off.
function builtinRulesetsOn() {
	return uci.get('singbox-ui', 'main', 'default_rulesets') !== '0';
}

function rulesetActive(s) {
	if (s.enabled === '0') return false;
	if (s.builtin === '1' && !builtinRulesetsOn()) return false;
	return true;
}

// tintBuiltinRow(td, trEl) — add .sb-builtin-row to the row owning the action cell.
//
// LuCI master hands renderRowActions the <tr> it is building. The LuCI shipped in
// OpenWrt 25.12 does NOT: its GridSection override is
// `renderRowActions(section_id) { return this.super(..., [section_id, _('Edit')]) }`,
// which drops every argument but the id, and TableSection.renderContents calls it
// without the row either. So trEl is undefined on a real router, and relying on it
// meant the buttons greyed out but the row was never tinted.
//
// The version-independent handle is the cell we just returned: the caller does
// `trEl.appendChild(this.renderRowActions(...))`, so one tick later td.parentNode
// IS the row. Looking the row up in the document instead would NOT work — LuCI
// assembles the whole table in memory and only inserts it later, so a
// getElementById on the next tick still finds nothing.
function tintBuiltinRow(td, trEl) {
	if (trEl && trEl.classList) { trEl.classList.add('sb-builtin-row'); return; }
	if (!td) return;
	window.setTimeout(function () {
		var tr = td.parentNode;
		if (tr && tr.classList) tr.classList.add('sb-builtin-row');
	}, 0);
}

// lockBuiltinRow(s, note, hideFn) — make every builtin row of a GridSection
// read-only. `disabled` is what greys the buttons out, so no extra CSS is needed
// for that; .sb-builtin-row only carries the row tint. `hideFn` is optional and
// filters the rows away entirely (the rule-sets' master switch uses it).
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
		tintBuiltinRow(td, trEl);
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
//     (a `{ content: str }` branch used to live here too — no caller ever
//      produced that shape),
//   * a Promise resolving to one of those object shapes.
// Used by importers/inbound.js (export_section) and widgets/action-bar.js
// (read_config / preview_config) — keep the markup/behaviour consistent.
function showJsonModal(title, contentOrPromise) {
	// The classes carry the styling (style.css .sb-json-modal-*). The inline
	// copies that used to sit here shadowed them AND disagreed — the class says
	// max-height 60vh, the inline said 50vh, and inline wins — so editing the
	// stylesheet did nothing.
	var pre = E('pre', { 'class': 'cbi-input-textarea sb-json-modal-pre' }, [_('Loading…')]);
	var status = E('div', { 'class': 'sb-json-modal-status' });

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
    prettyBytes:       prettyBytes,
    waitSubRefresh:    waitSubRefresh,
    addRenameField:    addRenameField,
    renameRefs:        renameRefs,
    renameSection:     renameSection,
    isBuiltin:         isBuiltin,
    builtinRulesetsOn: builtinRulesetsOn,
    rulesetActive:     rulesetActive,
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
