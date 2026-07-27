'use strict';
'require uci';
'require ui';
'require view.singbox-ui.lib.common as SbCommon';
'require view.singbox-ui.lib.rpc as SbRpc';

// JSON editor: export a section's sing-box JSON, let the user edit it, and turn
// what they hand back into UCI.
//
// Applying is a DIFF, not an overwrite. The backend (import_section) returns:
//   fields — the UCI options the JSON carried
//   known  — every option this descriptor COULD produce
//   extra  — json keys the descriptor does not model
//   tag    — the section name from the JSON
//
// so we can: write the changed fields, remove the `known` ones the JSON dropped
// (that is how you clear a field from the editor), and leave everything NOT in
// `known` completely alone — `enabled`, `builtin`, `nft_rules`, the whole `sub_*`
// family. Those have no JSON representation, and a full overwrite would wipe them.
//
// A changed `tag` renames THIS section. It must never create a second one and
// leave the original behind — so it goes through SbCommon.renameSection(), which
// re-creates the section under the new name (LuCI's uci API has no rename) and
// rewrites every by-name reference to it (route rules, group members, detours,
// dns.final, domain_resolver …).
//
// Nothing is written to the router here. Everything lands in LuCI's uci
// changeset, so Save & Apply commits it and Revert throws it away, exactly as
// with a hand-edited form.

// The kinds that have a JSON representation (mirrors lib/section_json.uc KINDS).
// A subscription outbound is not one of them: it is a URL that is fetched and
// expanded into many outbounds, so there is no single object that round-trips.
var JSON_KINDS = {
	inbound: 1, outbound: 1, dns_server: 1, dns_rule: 1, route_rule: 1, ruleset: 1,
};
var NO_JSON_OUTBOUND = { subscription: 1, url: 1, interface: 1 };

// hasJson(kind, sid) — is there a JSON object for this section at all?
function hasJson(kind, sid) {
	if (!JSON_KINDS[kind]) return false;
	if (kind !== 'outbound') return true;
	return !NO_JSON_OUTBOUND[uci.get('singbox-ui', sid, 'type') || ''];
}

function fetchJson(kind, sid) {
	return SbRpc.callExportSection(kind, sid).then(function (res) {
		if (!res || res.status !== 'ok')
			return { error: (res && res.message) || _('unknown error') };
		return { json: JSON.stringify(res.section, null, 2) };
	}, function (err) {
		return { error: (err && err.message) ? err.message : String(err) };
	});
}

// applyImport(kind, sid, r) — write the parsed result into the uci changeset.
// Returns the (possibly new) section id.
function applyImport(kind, sid, r) {
	var known = Array.isArray(r.known) ? r.known : [];
	var fields = r.fields || {};

	known.forEach(function (k) {
		if (Object.prototype.hasOwnProperty.call(fields, k)) {
			var v = fields[k];
			uci.set('singbox-ui', sid, k, Array.isArray(v) ? v.map(String) : String(v));
		} else {
			// In `known` but absent from the JSON: the user deleted it. Removing is
			// how a field is cleared from the editor — and an unset UCI option is
			// already the falsy/absent value, so this is also how a flag is turned
			// off without burying the section in `*_enabled '0'` lines.
			uci.unset('singbox-ui', sid, k);
		}
	});

	// Unknown keys ride along verbatim in json_extra, which the filler merges back
	// into the built object. The user has already confirmed them by this point.
	var extra = r.extra || {};
	if (Object.keys(extra).length) uci.set('singbox-ui', sid, 'json_extra', JSON.stringify(extra));
	else                           uci.unset('singbox-ui', sid, 'json_extra');

	// A changed tag renames THIS section — never spawns a new one — and drags every
	// reference to it along. renameSection() does both (LuCI has no uci.rename).
	if (r.tag && r.tag !== sid && SbCommon.renameSection(sid, r.tag)) return r.tag;
	return sid;
}

// A tag rename has to satisfy the same rules the Name field does: UCI section
// names live in ONE namespace per config file, and must be a plain uciname.
function tagError(sid, tag) {
	if (!tag || tag === sid) return null;
	if (!/^[A-Za-z0-9_-]+$/.test(tag))
		return _('Invalid tag "%s": use letters, digits, - and _ only.').format(tag);
	if (uci.get('singbox-ui', tag) != null)
		return _('Cannot rename to "%s": that name is already in use.').format(tag);
	return null;
}

// confirmUnknown(keys) -> Promise<bool>. The user asked for unknown keys to be
// kept rather than dropped, but not silently: they get named, and the user says
// yes or no.
function confirmUnknown(keys, onDone) {
	ui.showModal(_('Unrecognised fields'), [
		E('p', {}, _('These fields are not part of this section\'s form:')),
		E('ul', { 'style': 'margin:8px 0 8px 18px;font-family:monospace;' },
			keys.map(function (k) { return E('li', {}, k); })),
		E('p', {}, _('They will be stored as-is and merged into the generated config. A typo here reaches sing-box unchecked. Save them?')),
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', {
				'class': 'cbi-button',
				'click': function () { ui.hideModal(); onDone(false); }
			}, _('Cancel')),
			' ',
			E('button', {
				'class': 'cbi-button cbi-button-positive',
				'click': function () { ui.hideModal(); onDone(true); }
			}, _('Save anyway'))
		])
	]);
}

// openJsonEditor(kind, sid) — the editor modal. Its only entry point is the
// "JSON editor" button addJsonButtons() puts in the edit modal.
function openJsonEditor(kind, sid) {
	var ta = E('textarea', {
		'rows': 20,
		'class': 'cbi-input-textarea',
		'style': 'width:100%;font-family:monospace;font-size:90%;'
	}, _('Loading…'));
	var err = E('div', { 'class': 'sb-error', 'style': 'margin-top:8px;white-space:pre-wrap;' });
	var applyBtn;

	function setError(msg) { err.textContent = msg || ''; }

	function finish(r) {
		var newSid = applyImport(kind, sid, r);
		ui.hideModal();
		ui.addNotification(null,
			E('p', {}, _('Applied to "%s". Press "Save & Apply" to commit.').format(newSid)),
			'info');
	}

	function onApply() {
		setError('');
		var parsed;
		try { parsed = JSON.parse(ta.value); }
		catch (e) { setError(_('Invalid JSON: ') + e.message); return; }
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
			setError(_('Expected a JSON object.'));
			return;
		}

		// Check the rename BEFORE the RPC: a colliding tag would otherwise be
		// reported only after the round-trip, and a bad one must never reach
		// renameSection().
		var te = tagError(sid, parsed.tag);
		if (te) { setError(te); return; }

		applyBtn.disabled = true;
		SbRpc.callImportSection(kind, sid, JSON.stringify(parsed)).then(function (r) {
			applyBtn.disabled = false;
			if (!r || r.status !== 'ok') {
				setError(_('Import failed: ') + ((r && r.message) || _('unknown error')));
				return;
			}
			var unknown = Object.keys(r.extra || {});
			if (unknown.length) confirmUnknown(unknown, function (ok) { if (ok) finish(r); });
			else finish(r);
		}, function (e) {
			applyBtn.disabled = false;
			setError(_('RPC failed: ') + ((e && e.message) ? e.message : String(e)));
		});
	}

	applyBtn = E('button', {
		'class': 'cbi-button cbi-button-positive',
		'disabled': true,
		'click': onApply
	}, _('Apply'));

	ui.showModal(_('JSON editor — %s %s').format(kind, sid), [
		E('p', {}, _('Edit the sing-box JSON for this section. Only the fields you change are written; everything the form does not model (Enable, subscription settings, nftables flags) is left untouched.')),
		ta, err,
		E('div', { 'class': 'right', 'style': 'margin-top:12px;' }, [
			E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')),
			' ',
			applyBtn
		])
	]);

	fetchJson(kind, sid).then(function (res) {
		if (res.error) { ta.value = ''; setError(_('Error: ') + res.error); return; }
		ta.value = res.json;
		applyBtn.disabled = false;
	});
}

// disableWhenNoJson(o, kind, note) — grey the button out on a section that has no
// single JSON object (a subscription outbound).
function disableWhenNoJson(o, kind, note) {
	var origRender = o.renderWidget;
	o.renderWidget = function (section_id, option_index, cfgvalue) {
		var node = origRender.call(this, section_id, option_index, cfgvalue);
		if (hasJson(kind, section_id)) return node;
		var btn = (node && node.querySelector) ? node.querySelector('button') : null;
		if (btn) { btn.disabled = true; btn.title = note; }
		return node;
	};
}

// addJsonButtons(s, kind, form) — the per-grid wiring: an Export column, and a
// "JSON editor" button inside the edit modal.
function addJsonButtons(s, kind, form) {
	var tab = (s.tabs && s.tabs.length) ? s.tabs[0].name : 'basic';

	var o = s.taboption(tab, form.Button, '_export', _('JSON'));
	o.editable   = true;
	o.modalonly  = false;
	o.inputtitle = _('Export');
	o.inputstyle = 'action';
	o.onclick = function (ev, section_id) {
		SbCommon.showJsonModal(
			_('Export JSON — %s %s').format(kind, section_id),
			fetchJson(kind, section_id));
		return false;
	};
	disableWhenNoJson(o, kind, _('A subscription has no single JSON object: it is a URL that expands into many outbounds.'));

	o = s.taboption(tab, form.Button, '_json_edit', _('JSON editor'));
	o.modalonly  = true;
	o.inputtitle = _('Open JSON editor');
	o.inputstyle = 'action';
	o.description = _('Edit this section as sing-box JSON instead of filling in the form. The form is saved first (not applied) so the editor sees your current values.');
	o.onclick = function (ev, section_id) {
		// export_section reads UCI through its own cursor, which sees the on-disk
		// config plus the uci DELTA — but not LuCI's in-browser changeset. So a
		// section added in this session would come back "not found", and pending
		// edits to an existing one would be invisible. map.save() flushes the
		// changeset into the delta (it does NOT commit — Revert still works), which
		// is exactly what the editor needs to see.
		return this.map.save().then(function () {
			ui.hideModal();
			openJsonEditor(kind, section_id);
		}).catch(function (e) {
			ui.addNotification(null,
				E('p', {}, _('Cannot open the JSON editor: ') + (e && e.message ? e.message : String(e))),
				'error');
		});
	};
	disableWhenNoJson(o, kind, _('A subscription has no single JSON object to edit.'));
	return o;
}

// JSON_KINDS and openJsonEditor are NOT exported: nothing outside this file
// calls them (addJsonButtons is the entry point, hasJson/tagError/applyImport
// are what the unit tests drive).
return L.Class.extend({
	hasJson:        hasJson,
	tagError:       tagError,
	applyImport:    applyImport,
	addJsonButtons: addJsonButtons,
});
