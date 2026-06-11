// lib/clash.uc — sing-box experimental.clash_api. Pure: no I/O.
function build_clash_api(cur) {
	let s = cur.get_all("singbox-ui", "clash_api");
	if (s == null || s.enabled !== "1") return null;
	let listen = (s.listen != null && length(s.listen)) ? s.listen : "127.0.0.1";
	let port   = (s.port   != null && length(s.port))   ? s.port   : "9090";
	// Bracket IPv6 literals: `${listen}:${port}` with listen="::1" yields
	// ':::9090', which sing-box parses as port-of-empty-host (bind fails or
	// silently binds to a wrong interface). RFC 3986 / [host]:port form
	// disambiguates. Detect IPv6 by the presence of any ':' in the listen
	// string — IPv4 dotted-quad and hostnames never contain ':'.
	let addr;
	if (index(listen, ":") >= 0)
		addr = sprintf("[%s]:%s", listen, port);
	else
		addr = `${listen}:${port}`;
	let out = { external_controller: addr };
	if (s.secret != null && length(s.secret)) out.secret = s.secret;
	return out;
}
return { build_clash_api };
