// lib/clash.uc — sing-box experimental.clash_api. Pure: no I/O.
function build_clash_api(cur) {
	let s = cur.get_all("singbox-ui", "clash_api");
	if (s == null || s.enabled !== "1") return null;
	let listen = (s.listen != null && length(s.listen)) ? s.listen : "127.0.0.1";
	let port   = (s.port   != null && length(s.port))   ? s.port   : "9090";
	let out = { external_controller: `${listen}:${port}` };
	if (s.secret != null && length(s.secret)) out.secret = s.secret;
	return out;
}
return { build_clash_api };
