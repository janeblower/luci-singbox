'use strict';
'require form';
'require rpc';
'require ui';

// AWG-WARP plugin frontend module.
// Contributed outbound type: awg_warp.
// Called by outbounds.js via the formRendererFor() framework path.

var callRegister = rpc.declare({
	object: 'singbox-ui',
	method: 'warp_register',
	params: ['outbound', 'mode', 'conf'],
});

var callGenerate = rpc.declare({
	object: 'singbox-ui',
	method: 'awg_generate',
	params: ['outbound'],
});

var callInstall = rpc.declare({
	object: 'singbox-ui',
	method: 'awg_install',
});

var callStatus = rpc.declare({
	object: 'singbox-ui',
	method: 'awg_status',
});

function outboundTypes() {
	return [['awg_warp', _('AWG WARP')]];
}

// renderOutboundForm(type, sectionId, ctx)
//   ctx = { section: <cbi section>, map: <form.Map> }
//   Adds AWG-WARP-specific form controls to the cbi section.
function renderOutboundForm(type, sectionId, ctx) {
	var s = ctx.section;
	var o;

	// Install action — shown when AWG components are not yet present.
	// callStatus() is resolved at click time; no pre-render async needed.
	o = s.taboption('basic', form.Button, '_install', _('AWG components'));
	o.modalonly  = true;
	o.inputtitle = _('Install AWG + ip-full');
	o.inputstyle = 'apply';
	o.depends('type', 'awg_warp');
	o.onclick = function () {
		return callInstall().then(function (r) {
			var ok = r && r.status === 'ok';
			ui.addNotification(null,
				E('p', {}, ok ? _('AWG + ip-full installed successfully.') : _('Install failed: ') + (r && r.message || _('unknown error'))),
				ok ? 'info' : 'danger');
		});
	};

	// Register WARP account automatically.
	o = s.taboption('basic', form.Button, '_register', _('WARP account'));
	o.modalonly  = true;
	o.inputtitle = _('Register (Cloudflare WARP)');
	o.inputstyle = 'apply';
	o.depends('type', 'awg_warp');
	o.onclick = function (ev, sid) {
		return callRegister(sid, 'auto', '').then(function (r) {
			var ok = r && r.status === 'ok';
			ui.addNotification(null,
				E('p', {}, ok ? _('WARP account registered.') : _('Registration failed: ') + (r && r.message || _('unknown error'))),
				ok ? 'info' : 'danger');
		});
	};

	// Paste a WARP .conf file to register via paste mode.
	o = s.taboption('basic', form.TextValue, 'warp_paste', _('Paste WARP .conf'));
	o.modalonly = true;
	o.rows      = 6;
	o.optional  = true;
	o.depends('type', 'awg_warp');
	o.description = _('Paste the contents of a Cloudflare WARP .conf file to register via paste mode.');
	o.write = function (sid, val) {
		if (!val || !val.length) return;
		return callRegister(sid, 'paste', val).then(function (r) {
			var ok = r && r.status === 'ok';
			ui.addNotification(null,
				E('p', {}, ok ? _('WARP conf applied.') : _('Paste registration failed: ') + (r && r.message || _('unknown error'))),
				ok ? 'info' : 'danger');
		});
	};

	// Mimic protocol — controls the outer UDP camouflage.
	o = s.taboption('basic', form.ListValue, 'awg_mimic', _('Mimic protocol'));
	o.modalonly = true;
	o.depends('type', 'awg_warp');
	o.default   = 'auto';
	['auto', 'quic', 'dns', 'stun', 'dtls', 'sip', 'tls', 'static'].forEach(function (v) {
		o.value(v, v);
	});

	// Regenerate AWG keys/junk parameters.
	o = s.taboption('basic', form.Button, '_regen', _('AWG parameters'));
	o.modalonly  = true;
	o.inputtitle = _('Regenerate (WARP-safe)');
	o.inputstyle = 'action';
	o.depends('type', 'awg_warp');
	o.onclick = function (ev, sid) {
		return callGenerate(sid).then(function (r) {
			if (!r || r.status !== 'ok') {
				ui.addNotification(null,
					E('p', {}, _('Regenerate failed: ') + (r && r.message || _('unknown error'))),
					'danger');
				return;
			}
			ui.addNotification(null,
				E('p', {}, _('AWG parameters regenerated: Jc=%d Jmin=%d Jmax=%d').format(r.jc || 0, r.jmin || 0, r.jmax || 0)),
				'info');
		});
	};

	// IPv6 — enable IPv6 WARP masquerade.
	o = s.taboption('basic', form.Flag, 'ipv6_enabled', _('Enable IPv6'));
	o.modalonly = true;
	o.depends('type', 'awg_warp');
	o.default   = '0';
	o.description = _('Enable IPv6 auto-masquerade for WARP.');

	// MTU override — optional, empty = WAN−80 default.
	o = s.taboption('basic', form.Value, 'mtu_override', _('MTU override'));
	o.modalonly    = true;
	o.depends('type', 'awg_warp');
	o.optional     = true;
	o.datatype     = 'uinteger';
	o.placeholder  = _('empty = WAN−80');
}

return L.Class.extend({
	outboundTypes:      outboundTypes,
	renderOutboundForm: renderOutboundForm,
});
