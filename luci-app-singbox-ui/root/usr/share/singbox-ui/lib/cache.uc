// lib/cache.uc — sing-box experimental.cache_file.
// Reads `singbox-ui.cache` section:
//   enabled '1'                  → { enabled: true, path }
//   + store_fakeip '1'           → adds store_fakeip:true if fakeip.enabled too
//   path empty                   → defaults to /tmp/singbox-ui-cache.db
//   enabled '0' or absent        → null

let helpers = require("helpers");

function build_cache(cur) {
	let s = cur.get_all("singbox-ui", "cache");
	if (s == null || s.enabled !== "1") return null;
	let out = {
		enabled: true,
		path: (s.path != null && length(s.path)) ? s.path : "/tmp/singbox-ui-cache.db",
	};
	if (helpers.get_bool(cur, "fakeip", "enabled") && s.store_fakeip === "1")
		out.store_fakeip = true;
	return out;
}

return { build_cache };
