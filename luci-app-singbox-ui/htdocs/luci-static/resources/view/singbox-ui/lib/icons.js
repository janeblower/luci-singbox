'use strict';

// Inline SVG icons (Lucide). LuCI's E() builds nodes with document.createElement,
// which yields an HTMLUnknownElement for <svg> — the icon silently does not
// render. SVG needs createElementNS, so this module builds every node in the SVG
// namespace. Do NOT "simplify" this back onto E()/createElement.
//
// Size is set from CSS (.sb-icon in style.css), not width/height attributes.

var NS = 'http://www.w3.org/2000/svg';

var BASE = {
	'xmlns': NS,
	'viewBox': '0 0 24 24',
	'fill': 'none',
	'stroke': 'currentColor',
	'stroke-width': '2',
	'stroke-linecap': 'round',
	'stroke-linejoin': 'round'
};

function el(tag, attrs) {
	var node = document.createElementNS(NS, tag);
	for (var k in attrs) node.setAttribute(k, String(attrs[k]));
	return node;
}

// svg([['path', {d:…}], …], extraClass) -> <svg> in the SVG namespace.
function svg(children, cls, attrs) {
	var root = el('svg', Object.assign({}, BASE, attrs || {}));
	root.setAttribute('class', cls ? 'sb-icon ' + cls : 'sb-icon');
	(children || []).forEach(function (c) { root.appendChild(el(c[0], c[1])); });
	return root;
}

return L.Class.extend({
	svg: svg,

	loaderCircle: function () {
		return svg([['path', { 'd': 'M21 12a9 9 0 1 1-6.219-8.56' }]], 'sb-icon-spin');
	},
	copy: function () {
		return svg([
			['rect', { 'width': '14', 'height': '14', 'x': '8', 'y': '8', 'rx': '2', 'ry': '2' }],
			['path', { 'd': 'M4 16c-1.1 0-2-.9-2-2V4c0-1.1.9-2 2-2h10c1.1 0 2 .9 2 2' }]
		]);
	},
	link: function () {
		return svg([
			['path', { 'd': 'M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71' }],
			['path', { 'd': 'M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71' }]
		]);
	},
	x: function () {
		return svg([
			['path', { 'd': 'M18 6 6 18' }],
			['path', { 'd': 'm6 6 12 12' }]
		]);
	},
	pause: function () {
		return svg([
			['rect', { 'x': '14', 'y': '3', 'width': '5', 'height': '18', 'rx': '1' }],
			['rect', { 'x': '5', 'y': '3', 'width': '5', 'height': '18', 'rx': '1' }]
		]);
	},
	play: function () {
		return svg([['path', {
			'd': 'M5 5a2 2 0 0 1 3.008-1.728l11.997 6.998a2 2 0 0 1 .003 3.458l-12 7A2 2 0 0 1 5 19z'
		}]]);
	},
	search: function () {
		return svg([
			['path', { 'd': 'm21 21-4.34-4.34' }],
			['circle', { 'cx': '11', 'cy': '11', 'r': '8' }]
		]);
	},
	info: function () {
		return svg([
			['circle', { 'cx': '12', 'cy': '12', 'r': '10' }],
			['path', { 'd': 'M12 16v-4' }],
			['path', { 'd': 'M12 8h.01' }]
		]);
	},

	// Border-tracing "switching node" animation: a rect stretched to the host box
	// (hence no viewBox — it must scale to whatever it overlays), dashed via CSS
	// on pathLength=100 so one dash unit == 1% of the perimeter.
	snake: function () {
		var root = el('svg', { 'xmlns': NS, 'fill': 'none' });
		root.setAttribute('class', 'sb-snake');
		root.appendChild(el('rect', {
			'width': '100%', 'height': '100%', 'fill': 'none',
			'rx': '4', 'ry': '4', 'pathLength': '100'
		}));
		return root;
	}
});
