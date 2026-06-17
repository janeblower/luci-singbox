// lib/clash.uc — sing-box experimental.clash_api. Pure: no I/O.
// Declarative: the field→JSON mapping + external_controller composition live in
// the builder.settings.clash_api descriptor; this module only gates on enabled.
let reg    = require("builder.settings.registry");   // eager-loads clash_api descriptor
let filler = require("builder._filler");

function build_clash_api(cur) {
	let s = cur.get_all("singbox-ui", "clash_api");
	if (s == null || s.enabled !== "1") return null;
	let d = reg.get("clash_api", "clash_api");
	if (d == null) return null;
	return filler.build(d, s);
}
return { build_clash_api };
