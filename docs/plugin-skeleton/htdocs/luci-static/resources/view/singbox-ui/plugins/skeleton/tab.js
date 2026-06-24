'use strict';
'require form';

// Frontend module for the skeleton plugin.
//
// The core loader (lib/plugins.js) dynamically L.require()s this module when
// the plugin is enabled (plugins.skeleton_enabled=1 in UCI).  The module is
// loaded lazily — it is never fetched for disabled plugins.
//
// Export any subset of the methods below.  All are optional; omit what you
// do not need.
//
// IMPORTANT: in async catch blocks use console.error(), NOT L.error().
// L.error() in the LuCI runtime creates AND throws a tagged exception, which
// re-rejects the promise and defeats per-plugin isolation.

return {
	// -------------------------------------------------------------------------
	// tabs() — inject one or more tabs into the main singbox-ui view.
	//
	// Returns an array of tab descriptors.  Each descriptor must have:
	//   id:    unique string used as the tab identifier
	//   label: translated label shown in the tab bar
	//   build: function() returning a form.Map (or other renderable node)
	// -------------------------------------------------------------------------
	tabs: function () {
		return [{
			id:    'skeleton',
			label: _('Skeleton'),
			build: function () {
				var m = new form.Map('singbox-ui', _('Skeleton Plugin'),
					_('Example settings section added by the skeleton plugin.'));
				// var s = m.section(form.NamedSection, 'main', 'singbox-ui');
				// s.option(form.Value, 'skeleton_option', _('Option'));
				return m;
			},
		}];
	},

	// -------------------------------------------------------------------------
	// outboundTypes() — declare new outbound protocol type identifiers.
	//
	// Returns an array of [type_id, label] pairs.  type_id must be unique
	// across all plugins and core types.
	//
	// If you export outboundTypes you should also export renderOutboundForm
	// so the outbound tab knows how to build the form for your type.
	// -------------------------------------------------------------------------
	// outboundTypes: function () {
	// 	return [['skeleton_proto', _('Skeleton Protocol')]];
	// },

	// -------------------------------------------------------------------------
	// inboundTypes() — declare new inbound protocol type identifiers.
	// Same shape as outboundTypes.
	// -------------------------------------------------------------------------
	// inboundTypes: function () {
	// 	return [['skeleton_inbound', _('Skeleton Inbound')]];
	// },

	// -------------------------------------------------------------------------
	// renderOutboundForm(type, section, ctx) — build the form for one of your
	// outbound types.
	//
	// Called by the outbound tab when the user selects a type listed in
	// outboundTypes().  `section` is the active form.Section; add options to
	// it directly.  Return value is ignored.
	// -------------------------------------------------------------------------
	// renderOutboundForm: function (type, section, ctx) {
	// 	section.option(form.Value, 'server', _('Server'));
	// 	section.option(form.Value, 'server_port', _('Port'));
	// },

	// -------------------------------------------------------------------------
	// settingsSections(m) — inject sections into an existing settings Map.
	//
	// `m` is the form.Map passed by the General tab.  Use m.section() to add
	// new configuration sections.
	// -------------------------------------------------------------------------
	// settingsSections: function (m) {
	// 	var s = m.section(form.NamedSection, 'skeleton', 'skeleton', _('Skeleton'));
	// 	s.option(form.Flag, 'enabled', _('Enable'));
	// },

	// -------------------------------------------------------------------------
	// mode() — contribute one mode to the main-view mode switcher.
	//
	// Returns a single mode descriptor with:
	//   id:     unique string
	//   label:  translated name shown in the mode selector
	//   render: function() returning a DOM node
	//
	// Only one mode per plugin is used.
	// -------------------------------------------------------------------------
	// mode: function () {
	// 	return {
	// 		id:     'skeleton_easy',
	// 		label:  _('Easy'),
	// 		render: function () {
	// 			return E('div', { 'class': 'skeleton-easy-mode' },
	// 				_('Easy mode provided by the skeleton plugin.'));
	// 		},
	// 	};
	// },
};
