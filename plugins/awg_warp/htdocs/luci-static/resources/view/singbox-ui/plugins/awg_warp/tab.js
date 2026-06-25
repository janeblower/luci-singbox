'use strict';
'require form';
'require rpc';
'require ui';

// AWG-WARP plugin frontend module. Contributed outbound type: awg_warp.
// Регистрация/конфиг WARP — полностью автоматические (backend, на Save&Apply);
// форма несёт только установку компонентов + пользовательские тумблеры.

var callInstall = rpc.declare({ object: 'singbox-ui', method: 'awg_install' });
var callStatus  = rpc.declare({ object: 'singbox-ui', method: 'awg_status' });

// Префетч статуса компонентов один раз на загрузку модуля. К моменту, когда
// пользователь откроет модалку аутбаунда (действие много позже), промис уже
// разрешён и _awgReady доступен синхронно в renderOutboundForm.
var _awgReady = null;  // null=неизвестно, true/false после ответа
var whenReady = callStatus().then(function (r) {
	_awgReady = !!(r && r.ready); return _awgReady;
}).catch(function () { _awgReady = false; return false; });

// Pure-helper: состояние install-кнопки по флагу готовности (тестируется).
function installState(ready) {
	return ready === true
		? { readonly: true,  title: _('Installed') }
		: { readonly: false, title: _('Install AWG + ip-full') };
}

function outboundTypes() { return [['awg_warp', _('AWG WARP')]]; }

function renderOutboundForm(type, sectionId, ctx) {
	var s = ctx.section;
	var o;

	// Install — disabled когда компоненты уже стоят (req 1).
	var st = installState(_awgReady);
	o = s.taboption('basic', form.Button, '_install', _('AWG components'));
	o.modalonly  = true;
	o.inputtitle = st.title;
	o.inputstyle = 'apply';
	o.readonly   = st.readonly;
	o.depends('type', 'awg_warp');
	o.onclick = function () {
		if (_awgReady === true) return;  // уже установлено, кнопка disabled
		return callInstall().then(function (r) {
			var ok = r && r.status === 'ok';
			if (ok) { _awgReady = true; }
			ui.addNotification(null,
				E('p', {}, ok ? _('AWG + ip-full installed successfully.')
				              : _('Install failed: ') + (r && r.message || _('unknown error'))),
				ok ? 'info' : 'danger');
		});
	};

	// Storage location — RAM (ephemeral) / Flash (persists).
	o = s.taboption('basic', form.ListValue, 'warp_storage', _('Config storage'));
	o.modalonly = true;
	o.depends('type', 'awg_warp');
	o.default = 'ram';
	o.value('ram',   _('RAM (/tmp) — re-registers on reboot'));
	o.value('flash', _('Flash (/etc) — persists across reboot'));
	o.description = _('Where the WARP config is stored. RAM is ephemeral (re-registers on each boot); Flash persists but wears flash memory.');

	// Mimic protocol — controls the outer UDP camouflage.
	o = s.taboption('basic', form.ListValue, 'awg_mimic', _('Mimic protocol'));
	o.modalonly = true;
	o.depends('type', 'awg_warp');
	o.default   = 'auto';
	['auto', 'quic', 'dns', 'stun', 'dtls', 'sip', 'tls', 'static'].forEach(function (v) {
		o.value(v, v);
	});

	// IPv6 — enable IPv6 WARP masquerade.
	o = s.taboption('basic', form.Flag, 'ipv6_enabled', _('Enable IPv6'));
	o.modalonly = true;
	o.depends('type', 'awg_warp');
	o.default   = '0';

	// MTU override — optional, empty = WAN−80 default.
	o = s.taboption('basic', form.Value, 'mtu_override', _('MTU override'));
	o.modalonly   = true;
	o.depends('type', 'awg_warp');
	o.optional    = true;
	o.datatype    = 'uinteger';
	o.placeholder = _('empty = WAN−80');
}

return L.Class.extend({
	outboundTypes:      outboundTypes,
	renderOutboundForm: renderOutboundForm,
	installState:       installState,
	whenReady:          whenReady,
});
