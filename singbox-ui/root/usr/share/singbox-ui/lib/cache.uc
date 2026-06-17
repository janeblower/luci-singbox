// lib/cache.uc — sing-box experimental.cache_file.
// Field→JSON mapping is declarative (builder.settings.cache); this module owns
// the two cross-cutting pieces the filler can't express: storage→path
// resolution and the fakeip cross-gate (store_fakeip only when a fakeip
// dns_server is enabled). cache_db_path() is the single source of truth for the
// on-disk path (consumed by nft-rulesets.uc).
let reg    = require("builder.settings.registry");
let filler = require("builder._filler");

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
	let d = reg.get("cache", "cache");
	let out = filler.build(d, s);
	out.path = resolve_path(s);
	// fakeip cross-gate: store_fakeip is meaningless without a fakeip server.
	let has_fakeip = false;
	cur.foreach("singbox-ui", "dns_server", function(dsrv) {
		if (dsrv.enabled !== "0" && dsrv.type === "fakeip") has_fakeip = true;
	});
	if (!has_fakeip) delete out.store_fakeip;
	return out;
}

// cache_db_path(cur) — абсолютный путь cache.db, если секция cache включена,
// иначе null. Единый источник истины для тех, кому нужен путь файла кэша (не
// только JSON-конфиг): resolve_path даёт ram/flash/custom, enabled-гейт тот же,
// что в build_cache. Потребитель — cache-extraction nft-rule-set'ов
// (subscription.uc): без включённого cache_file файла cache.db не существует.
function cache_db_path(cur) {
	let s = cur.get_all("singbox-ui", "cache");
	if (s == null || s.enabled !== "1") return null;
	return resolve_path(s);
}

return { build_cache, cache_db_path };
