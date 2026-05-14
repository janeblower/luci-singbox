// Local-test stub of the OpenWrt ucode-mod-uci module.
// Implements just enough of the cursor API for generate.uc tests:
//   cursor(uci_dir).get(config, section[, opt])
//   cursor(uci_dir).get_all(config, section)
//   cursor(uci_dir).foreach(config, type, cb)
//
// Section objects carry the standard ".name" / ".type" / ".anonymous" keys
// just like libuci does.

let fs = require("fs");

function trim(s) {
	return replace(s, /^[ \t\r\n]+|[ \t\r\n]+$/g, "");
}

function parse_uci_file(path) {
	let f = fs.open(path, "r");
	if (!f) return null;

	let sections = {};
	let order    = [];
	let by_type  = {};
	let cur      = null;
	let anon_idx = 0;

	for (let line = f.read("line"); length(line); line = f.read("line")) {
		let trimmed = trim(line);
		if (!length(trimmed) || substr(trimmed, 0, 1) === "#") continue;

		let m = match(trimmed, /^config[ \t]+([^ \t]+)[ \t]+'([^']*)'[ \t]*$/);
		if (!m) m = match(trimmed, /^config[ \t]+([^ \t]+)[ \t]+([^ \t]+)[ \t]*$/);
		let m_anon = m ? null : match(trimmed, /^config[ \t]+([^ \t]+)[ \t]*$/);
		if (m || m_anon) {
			let stype = m ? m[1] : m_anon[1];
			let sname = m ? m[2] : sprintf("cfg%06d", anon_idx++);
			cur = {
				".name":       sname,
				".type":       stype,
				".anonymous":  !m,
				".index":      length(order),
			};
			sections[sname] = cur;
			push(order, sname);
			if (!by_type[stype]) by_type[stype] = [];
			push(by_type[stype], cur);
			continue;
		}

		let mo = match(trimmed, /^option[ \t]+([^ \t]+)[ \t]+'(.*)'[ \t]*$/);
		if (!mo) mo = match(trimmed, /^option[ \t]+([^ \t]+)[ \t]+(.+)$/);
		if (mo && cur) {
			cur[mo[1]] = mo[2];
			continue;
		}

		let ml = match(trimmed, /^list[ \t]+([^ \t]+)[ \t]+'(.*)'[ \t]*$/);
		if (!ml) ml = match(trimmed, /^list[ \t]+([^ \t]+)[ \t]+(.+)$/);
		if (ml && cur) {
			if (!cur[ml[1]]) cur[ml[1]] = [];
			push(cur[ml[1]], ml[2]);
			continue;
		}
	}
	f.close();

	return { sections, order, by_type };
}

function make_cursor(uci_dir) {
	let dir   = uci_dir ?? "/etc/config";
	let cache = {};

	function load(name) {
		if (!cache[name]) {
			cache[name] = parse_uci_file(dir + "/" + name)
			              ?? { sections: {}, order: [], by_type: {} };
		}
		return cache[name];
	}

	return {
		get: function(config, section, opt) {
			let c = load(config);
			let s = c.sections[section];
			if (!s) return null;
			if (opt == null) return s[".type"];
			let v = s[opt];
			return (v == null) ? null : v;
		},

		get_all: function(config, section) {
			let c = load(config);
			return c.sections[section] ?? null;
		},

		foreach: function(config, stype, cb) {
			let c = load(config);
			let arr = c.by_type[stype] ?? [];
			for (let s in arr) cb(s);
		},
	};
}

return {
	cursor: make_cursor,
};
