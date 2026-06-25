// lib/plugins/awg_warp/warp.uc — Cloudflare WARP registration (anonymous /reg).
// Anonymous POST to CF /reg (spec §2.1). Binaries via env seams for testability.
let fs      = require("fs");
let helpers = require("helpers");

const AWG_BIN = getenv("AWG_BIN") || "awg";
const CURL    = getenv("CURL")    || "curl";
const CF_URL  = "https://api.cloudflareclient.com/v0a2158/reg";
const CF_VER  = "a-6.10-2158";
const CF_UA   = "okhttp/3.12.1";

function _run(cmd) {
	let p = fs.popen(cmd);
	if (!p) return null;
	let out = p.read("all") ?? "";
	p.close();
	return out;
}

function _b64_rand(n) {
	let f = fs.open("/dev/urandom", "r");
	let s = "";
	let alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
	let raw = f ? f.read(n) : null;
	if (f) f.close();
	for (let i = 0; i < n; i++) {
		let v = (raw != null && i < length(raw)) ? ord(raw, i) : i;
		s += substr(alpha, v % 62, 1);
	}
	return s;
}

function register_auto() {
	let priv = trim(_run(sprintf("%s genkey", AWG_BIN)) ?? "");
	if (!length(priv)) return { ok: false, error: "awg genkey failed" };

	let pub = trim(_run(sprintf("printf %%s %s | %s pubkey", helpers.sq(priv), AWG_BIN)) ?? "");
	if (!length(pub)) return { ok: false, error: "awg pubkey failed" };

	let install_id = _b64_rand(22);
	let body = sprintf(
		"{\"key\":\"%s\",\"install_id\":\"%s\",\"fcm_token\":\"%s:APA91b\",\"tos\":\"2020-01-01T00:00:00.000Z\",\"model\":\"Android\",\"type\":\"Android\",\"locale\":\"en_US\"}",
		pub, install_id, install_id
	);

	let cmd = sprintf("%s -s -m 20 -X POST %s -H %s -H %s -H %s --data %s",
		CURL,
		helpers.sq(CF_URL),
		helpers.sq("User-Agent: " + CF_UA),
		helpers.sq("CF-Client-Version: " + CF_VER),
		helpers.sq("Content-Type: application/json; charset=UTF-8"),
		helpers.sq(body));

	let resp = _run(cmd) ?? "";
	let j;
	try { j = json(resp); } catch (e) { return { ok: false, error: "CF response not JSON" }; }
	if (j == null || j.config == null)
		return { ok: false, error: "CF registration failed (API drift?)" };

	let cfg  = j.config;
	let v4   = ((cfg.interface ?? {}).addresses ?? {}).v4 ?? "";
	let v6   = ((cfg.interface ?? {}).addresses ?? {}).v6 ?? "";
	let peer = (cfg.peers ?? [])[0] ?? {};

	let creds = {
		private_key:     priv,
		peer_public_key: peer.public_key ?? "",
		address_v4:      length(v4) ? (v4 + "/32") : "172.16.0.2/32",
		address_v6:      length(v6) ? (v6 + "/128") : "",
		endpoint:        ((peer.endpoint ?? {}).host) ?? "engage.cloudflareclient.com:2408",
		client_id:       cfg.client_id ?? "",
	};
	if (!length(creds.peer_public_key))
		return { ok: false, error: "no peer key in CF response" };
	return { ok: true, creds };
}

return { register_auto };
