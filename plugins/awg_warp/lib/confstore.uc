// lib/plugins/awg_warp/confstore.uc — WARP .conf артефакт: путь, рендер, парсинг, ensure.
// .conf — единый источник правды (creds + AWG-params). Существование файла =
// сигнал «не регистрировать заново». Бинарники/пути — через env-seams (тесты).
let fs     = require("fs");
let iface  = require("plugins.awg_warp.iface");
let warp   = require("plugins.awg_warp.warp");
let awggen = require("plugins.awg_warp.awggen");

const RAM_BASE   = getenv("SINGBOX_TMPDIR")   || "/tmp/singbox-ui";
const FLASH_BASE = getenv("SB_AWG_FLASH_DIR") || "/etc/singbox-ui";

// conf_path — per-outbound путь .conf для режима хранения. iface_name() уже
// санитизирует имя секции (HIGH-severity injection guard для пути).
function conf_path(section, storage) {
	let base = (storage == "flash") ? FLASH_BASE : RAM_BASE;
	return sprintf("%s/%s.conf", base, iface.iface_name(section));
}

// render_setconf — genl-only тело для `awg setconf` (НЕ содержит Address/MTU —
// awg setconf их отвергает; они применяются через ip addr/link отдельно).
function render_setconf(wg) {
	let s = "[Interface]\n";
	s += sprintf("PrivateKey = %s\n", wg.private_key ?? "");
	s += sprintf("Jc = %d\nJmin = %d\nJmax = %d\n", wg.jc, wg.jmin, wg.jmax);
	s += sprintf("S1 = %d\nS2 = %d\nS3 = %d\nS4 = %d\n", wg.s1, wg.s2, wg.s3, wg.s4);
	s += sprintf("H1 = %d\nH2 = %d\nH3 = %d\nH4 = %d\n", wg.h1, wg.h2, wg.h3, wg.h4);
	if (length(`${wg.i1 ?? ""}`)) s += sprintf("I1 = %s\n", wg.i1);
	s += "[Peer]\n";
	s += sprintf("PublicKey = %s\n", wg.peer_public_key ?? "");
	s += sprintf("Endpoint = %s\n", wg.endpoint ?? "");
	s += "AllowedIPs = 0.0.0.0/0, ::/0\n";
	s += "PersistentKeepalive = 25\n";
	return s;
}

// render_conf — полный человекочитаемый .conf (creds + params + Address/MTU).
// v6 Address закомментирована (#) когда ipv6_enabled=false.
function render_conf(wg, mtu, ipv6_enabled) {
	let setconf = render_setconf(wg);
	let addr = sprintf("Address = %s", wg.address_v4 ?? "172.16.0.2/32");
	if (length(`${wg.address_v6 ?? ""}`))
		addr += "\n" + (ipv6_enabled ? "" : "#") + sprintf("Address = %s", wg.address_v6);
	return replace(setconf, "[Peer]", sprintf("%s\nMTU = %d\n[Peer]", addr, mtu));
}

// parse_full — читает creds + AWG-params из .conf. Построчный скан с разбором по
// первому '=' (НЕТ динамических regex/(?:...)). Закомментированные (#) строки
// игнорируются. Неполные creds → null. Отсутствующие AWG-params → WARP-safe
// дефолты.
function parse_full(text) {
	text = `${text ?? ""}`;
	let wg = {
		private_key: "", peer_public_key: "", address_v4: "", address_v6: "",
		endpoint: "", jc: 8, jmin: 64, jmax: 900,
		s1: 0, s2: 0, s3: 0, s4: 0, h1: 1, h2: 2, h3: 3, h4: 4, i1: "",
	};
	let addr = "";
	for (let line in split(text, "\n")) {
		let t = trim(line);
		let eq = index(t, "=");
		if (eq < 1) continue;
		let key = trim(substr(t, 0, eq));
		let val = trim(substr(t, eq + 1));
		if      (key == "PrivateKey") wg.private_key = val;
		else if (key == "PublicKey")  wg.peer_public_key = val;
		else if (key == "Endpoint")   wg.endpoint = val;
		else if (key == "Address")    addr = (length(addr) ? addr + "," : "") + val;
		else if (key == "Jc")   wg.jc = int(val);
		else if (key == "Jmin") wg.jmin = int(val);
		else if (key == "Jmax") wg.jmax = int(val);
		else if (key == "S1")   wg.s1 = int(val);
		else if (key == "S2")   wg.s2 = int(val);
		else if (key == "S3")   wg.s3 = int(val);
		else if (key == "S4")   wg.s4 = int(val);
		else if (key == "H1")   wg.h1 = int(val);
		else if (key == "H2")   wg.h2 = int(val);
		else if (key == "H3")   wg.h3 = int(val);
		else if (key == "H4")   wg.h4 = int(val);
		else if (key == "I1")   wg.i1 = val;
	}
	for (let part in split(addr, ",")) {
		let a = trim(part);
		if (index(a, ":") >= 0) wg.address_v6 = a;
		else if (length(a))     wg.address_v4 = a;
	}
	if (!length(wg.private_key) || !length(wg.peer_public_key) || !length(wg.endpoint))
		return null;
	return wg;
}

return { conf_path, render_setconf, render_conf, parse_full };
