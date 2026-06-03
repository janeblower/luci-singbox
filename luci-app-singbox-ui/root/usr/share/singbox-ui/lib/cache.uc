// lib/cache.uc — sing-box experimental.cache_file.
// UCI `cache` section:
//   enabled '1'        → on
//   storage  ram|flash|custom (default ram)
//   path     absolute path; required when storage=custom, else derived:
//                 ram   → /tmp/singbox-ui-cache.db
//                 flash → /etc/sing-box/cache.db
//   store_fakeip '1'   → adds store_fakeip:true when an enabled fakeip
//                        dns_server exists; otherwise dropped silently.

function resolve_path(s) {
	let storage = (s.storage == null || s.storage === "") ? "ram" : s.storage;
	if (storage === "flash") return "/etc/sing-box/cache.db";
	if (storage === "custom") {
		if (s.path != null && length(s.path)) return s.path;
		warn("cache.uc: storage=custom without path; falling back to /tmp\n");
	}
	return "/tmp/singbox-ui-cache.db";
}

function build_cache(cur) {
	let s = cur.get_all("singbox-ui", "cache");
	if (s == null || s.enabled !== "1") return null;
	let out = {
		enabled: true,
		path: resolve_path(s),
	};
	let has_fakeip = false;
	cur.foreach("singbox-ui", "dns_server", function(d) {
		if (d.enabled !== "0" && d.type === "fakeip") has_fakeip = true;
	});
	if (has_fakeip && s.store_fakeip === "1")
		out.store_fakeip = true;
	return out;
}

return { build_cache };
