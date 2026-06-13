'use strict';

// Module singleton for per-page view state that used to live on window.*
// (spec S2-5). A LuCI module returning L.Class.extend({...}) is evaluated
// once and shared by every 'require', so this closed-over object is a stable
// singleton — no window globals, no cross-test leakage, no re-render races.
var _schema = {};
var _coreVersion = '';

return L.Class.extend({
	getSchema:      function () { return _schema; },
	setSchema:      function (s) { _schema = s || {}; },
	getCoreVersion: function () { return _coreVersion; },
	setCoreVersion: function (v) { _coreVersion = v || ''; },
});
