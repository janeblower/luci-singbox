#!/usr/bin/ucode
// Subscription fetcher and refresh driver (subscriptions only).
// Subcommands:
//   fetch-subs                              — download all subscription outbounds
//   refresh [force] [name]                  — refresh stale subscriptions
//   sub-status                              — print subscription status JSON
//
// Body parsing (formats, Clash YAML, sing-box JSON, base64) lives in
// lib/subformat.uc. This file owns the network side, the caches and the locks.
//
// Env overrides (used by tests):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)
//   SINGBOX_SUB_CACHE (default /etc/singbox-ui/sub-cache) — persistent cache
//   UCI_CONFIG_DIR (honoured by require("uci").cursor)
//   SINGBOX_NO_RELOAD=1 — refresh skips the init.d reload (tests)
//   SINGBOX_INITD  (default /etc/init.d/singbox-ui) — init.d path for reload (tests)
//   SINGBOX_RETRY_SLEEP (default 2) — seconds between download retries
//   SINGBOX_SB_VERSION — pin the sing-box version used in the default UA

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
// Cap subscription bodies so a hostile or runaway source cannot fill a 128–256 MB
// router's tmpfs. Enforced in TWO places: curl aborts the transfer at
// --max-filesize (so a huge body never lands on disk at all), and fetch_one
// keeps its post-download fs.stat() guard for the case curl cannot know the size
// up front (no Content-Length -> curl only stops once it exceeds the cap).
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB

// C1: persistent "last known good" cache. /tmp is a tmpfs — after a reboot the
// subscription is EMPTY until the first successful fetch, and sing-box starts
// with no outbounds at all. Keep a copy on flash and restore it before the boot
// fetch. 0700/0600 throughout: a node line carries the password/uuid.
const CACHE_DIR  = getenv("SINGBOX_SUB_CACHE") || "/etc/singbox-ui/sub-cache";

// C4: refresh lock. ucode has no flock(), so — exactly like nftables.uc's
// .apply.lock / init.d's .lifecycle.lock — the lock IS a directory: mkdir is the
// atomic test-and-set. Cron (*/15) and a UI "refresh now" click otherwise run
// two fetches and two reloads over each other.
const LOCK_DIR   = `${TMPDIR}/.sub.lock`;
const LOCK_STALE = 600;   // a lock older than this is a crashed run, not a live one

// init.d reload seam. reload is stop+start (sing-box has no signal reload) —
// C3: only ever invoked when the node set ACTUALLY changed.
const SINGBOX_INITD = getenv("SINGBOX_INITD") || "/etc/init.d/singbox-ui";

// curl binary seam (tests override via env). A subscription is fetched directly
// unless its section sets sub_proxy (see proxy_of) — the case where the panel
// itself is blocked and only the tunnel can reach it.
const CURL = getenv("CURL") || "/usr/bin/curl";
const RETRY_SLEEP = (getenv("SINGBOX_RETRY_SLEEP") != null) ? +getenv("SINGBOX_RETRY_SLEEP") : 2;
const RETRIES = 3;

// U1/U2/H2: User-Agent profiles. Panels routinely serve a DIFFERENT format (or a
// HTML "open in the app" stub) per UA — a Chrome UA, our old default, is the one
// that gets the stub. We now default to Happ's UA (richest per-location grouped
// format) and rotate through the other client UAs until a body actually PARSES.
const UA_ORDER = [ "happ", "sing-box", "v2rayn", "v2rayng", "mihomo", "clash.meta" ];
const UA_STATIC = {
	happ:        "Happ/1.0",
	v2rayn:      "v2rayN/6.42",
	v2rayng:     "v2rayNG/1.8.5",
	mihomo:      "mihomo/1.18.0",
	"clash.meta": "Clash.Meta/1.18.0",
};

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");
let subformat = require("subformat");

// Two channels: log() is ops-info, log_err() is errors. They both write to
// stderr (init.d/cron route it to syslog) but log_err tags severity so an
// operator reading logread can tell the two apart.
function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn("error: " + msg + "\n"); }

// popen_line(cmd) — first line of a command's stdout, or "". Every external
// utility is optional on OpenWrt (CLAUDE.md), so callers must tolerate "".
function popen_line(cmd) {
	let p = null;
	try { p = fs.popen(cmd, "r"); } catch (_) { return ""; }
	if (!p) return "";
	let out = "";
	try { out = p.read("all") ?? ""; } catch (_) { out = ""; }
	try { p.close(); } catch (_) {}
	return trim(split(out, "\n")[0] ?? "");
}

function have_bin(name) {
	return popen_line("command -v " + helpers.sq(name) + " 2>/dev/null") !== "";
}

function read_file(path) {
	let f = fs.open(path, "r");
	if (!f) return null;
	let body = null;
	try { body = f.read("all"); } catch (_) { body = null; }
	f.close();
	return body;
}

// sing-box version for the default UA. Cached for the process lifetime; a
// missing binary (or a test env) falls back to a plausible release.
let _sb_ver = null;
function sb_version() {
	if (_sb_ver != null) return _sb_ver;
	_sb_ver = getenv("SINGBOX_SB_VERSION") ?? "";
	if (_sb_ver === "") {
		let l = popen_line("sing-box version 2>/dev/null");
		let m = match(l, /([0-9]+\.[0-9]+\.[0-9]+)/);
		_sb_ver = m ? m[1] : "1.11.0";
	}
	return _sb_ver;
}

// ua_of(id) — a known profile id, or a literal UA string (back-compat: existing
// configs hold a full Chrome UA in sub_user_agent).
function ua_of(id) {
	if (id == null || id === "") return "sing-box/" + sb_version();
	if (id === "sing-box") return "sing-box/" + sb_version();
	if (UA_STATIC[id] != null) return UA_STATIC[id];
	return id;
}

// hdr_safe(v) — a header VALUE crosses into curl's argv. CR/LF (and any control
// byte) there is header injection; /tmp/sysinfo/model and the UCI hwid are both
// operator-writable, so scrub rather than trust.
function hdr_safe(v) {
	let out = "";
	for (let i = 0; i < length(v); i++) {
		let c = ord(v, i);
		if (c >= 32 && c !== 127) out += chr(c);
	}
	return trim(out);
}

let _hwid_cache = null;
// auto_hwid() — md5(MAC + model) rendered xxxx-xxxx-xxxx-xxxx. Remnawave/Happ
// panels bind a config to a device and hand back an empty body without it.
function auto_hwid() {
	if (_hwid_cache != null) return _hwid_cache;
	let mac = "";
	for (let iface in ["eth0", "br-lan", "lan"]) {
		let v = read_file(`/sys/class/net/${iface}/address`);
		if (v != null && trim(v) !== "") { mac = trim(v); break; }
	}
	let model = trim(read_file("/tmp/sysinfo/model") ?? "");
	let seed = mac + model;
	if (seed === "") { _hwid_cache = ""; return ""; }
	let hex = "";
	if (have_bin("md5sum")) {
		let l = popen_line("printf %s " + helpers.sq(seed) + " | md5sum 2>/dev/null");
		let m = match(l, /^([0-9a-f]{32})/);
		if (m) hex = m[1];
	}
	// No md5sum (or it failed): fnv1a32 twice gives the same 16 hex digits the
	// format needs. Not a digest — an id, and a stable one, which is all a panel
	// uses it for.
	if (hex === "") hex = helpers.fnv1a32(seed) + helpers.fnv1a32(seed + "\x01");
	_hwid_cache = sprintf("%s-%s-%s-%s", substr(hex, 0, 4), substr(hex, 4, 4),
	                      substr(hex, 8, 4), substr(hex, 12, 4));
	return _hwid_cache;
}

// hwid_for(cur, name) — explicit sub_hwid wins; otherwise derive one unless
// sub_auto_hwid is switched off.
function hwid_for(cur, name) {
	let h = hdr_safe(helpers.uci_get_or_empty(cur, name, "sub_hwid"));
	if (h !== "") return h;
	if (helpers.uci_get_or_empty(cur, name, "sub_auto_hwid") === "0") return "";
	return auto_hwid();
}

// provider_headers(hwid) — the Remnawave/Happ device-identification set.
function provider_headers(hwid) {
	let hdrs = [
		"X-Device-OS: OpenWrt Linux",
		"Accept-Language: ru-RU,en,*",
		"X-Device-Locale: EN",
	];
	if (hwid !== "") push(hdrs, "X-HWID: " + hwid);
	let model = hdr_safe(trim(read_file("/tmp/sysinfo/model") ?? ""));
	if (model !== "") push(hdrs, "X-Device-Model: " + model);
	let rel = hdr_safe(popen_line("uname -r 2>/dev/null"));
	if (rel !== "") push(hdrs, "X-Ver-OS: " + rel);
	return hdrs;
}

// I/O seams — overridable for tests. BOTH `let` bindings are declared here,
// BEFORE the setter helpers below close over and assign to them.
let _reader = read_file;

// _fetcher(jobs) — one curl per job. Sets j.rc to curl's exit status (D1 needs
// it: 5/6 are DNS failures, where a retry is pure latency). All argv is
// shell-quoted via helpers.sq() so a hostile url/ua/header cannot break out.
let _fetcher = function(jobs) {
	if (!length(jobs)) return jobs;
	for (let j in jobs) {
		let to = (j.opts && j.opts.timeout) ? j.opts.timeout : 15;
		let argv = [ CURL, "-fsSL", "--max-time", sprintf("%d", to),
		             // D2: a panel that accepts the connection and then dribbles
		             // (or stalls forever) used to hold the whole refresh hostage
		             // until --max-time; abort a stalled transfer instead.
		             "--connect-timeout", "15", "--speed-time", "15", "--speed-limit", "1",
		             "--max-filesize", sprintf("%d", MAX_BODY),
		             "-A", j.ua ];
		if (j.proxy) push(argv, "-x", j.proxy);
		for (let h in (j.headers ?? [])) { push(argv, "-H"); push(argv, h); }
		push(argv, "-D", j.hdr_path, "-o", j.body_path, j.url);
		let quoted = [];
		for (let a in argv) push(quoted, helpers.sq(a));
		let line = join(" ", quoted) + " >/dev/null 2>&1";
		let rc = 1;
		try { rc = system(["/bin/sh", "-c", line]); } catch (_) { rc = 1; }
		j.rc = rc;
	}
	return jobs;
};

// _set_io_for_test(fetcher, reader) — install mock I/O. Either arg may be null.
function _set_io_for_test(fetcher, reader) {
	if (fetcher != null) _fetcher = fetcher;
	if (reader != null)  _reader  = reader;
}

// _set_fetcher_for_test(fn) — dedicated seam to inject a mock fetcher.
function _set_fetcher_for_test(fn) { _fetcher = fn; }

// _read_raw_for_test(path) — thin wrapper so a test can verify the reader seam.
function _read_raw_for_test(path) { return _reader(path); }

// write_atomic(path, body, mode) — write to a sibling tmp file, flush via close,
// then fs.rename over `path`. Guarantees sing-box never reads a half-written
// sub_<name>.txt and never leaks the fd on a write exception.
function write_atomic(path, body, mode) {
	let m = mode ?? 0o600;
	let tmp = sprintf("%s.tmp.%d", path, time());
	let f = fs.open(tmp, "w", m);
	if (!f) { log_err(`write_atomic: cannot open ${tmp}`); return false; }
	let ok = true;
	try { f.write(body); } catch (e) { ok = false; }
	f.close();
	try { fs.chmod(tmp, m); } catch (_) {}   // a pre-existing tmp keeps its old mode
	if (!ok) {
		log_err(`write_atomic: write to ${tmp} failed`);
		try { fs.unlink(tmp); } catch (_) {}
		return false;
	}
	let renamed = false;
	try { renamed = fs.rename(tmp, path); } catch (_) { renamed = false; }
	if (!renamed) {
		log_err(`write_atomic: rename ${tmp} -> ${path} failed`);
		try { fs.unlink(tmp); } catch (_) {}
		return false;
	}
	return true;
}

// ------------------------------------------------------------------ metadata

const MAX_TITLE    = 120;
const MAX_ANNOUNCE = 500;
const MAX_UI_INT   = 10000000000000;   // 1e13 — see clamp below

function clip(s, n) { return (length(s) > n) ? substr(s, 0, n) : s; }

// safe_url(v) — provider-supplied links are rendered as <a href> by the
// dashboard. Only http(s) survives; javascript:/data: never reach the DOM.
function safe_url(v) {
	let t = trim(v);
	return match(lc(t), /^https?:\/\/[^ \t]+$/) ? t : null;
}

// maybe_b64(v) — panels send `base64:<payload>` for anything non-ASCII.
function maybe_b64(v) {
	let b = match(v, /^base64:(.*)$/);
	if (!b) return v;
	// SEC-5: distinguish a decode FAILURE from an empty (but valid) decode. On
	// ANY successful decode (even "") honour it; only a hard failure falls back
	// to the raw payload — and then WITHOUT the "base64:" prefix, so the
	// dashboard never renders a literal "base64:..." value.
	let dec = null;
	try { dec = b64dec(trim(b[1])); } catch (_) {}
	return (dec != null) ? dec : trim(b[1]);
}

function parse_userinfo(v) {
	let info = {};
	for (let kv in split(v, ";")) {
		let p = match(trim(kv), /^([A-Za-z_]+)=([0-9]+)$/);
		if (!p) continue;
		// The header is attacker-controlled. An absurd `expire` used to reach the
		// Dashboard verbatim, where new Date(sec*1000).toISOString() threw and
		// bricked the tab. Clamp at the trust boundary: anything past year ~2286
		// (or a nonsense byte count) is not a value we can render — drop it.
		let n = +p[2];
		if (n < 0 || n > MAX_UI_INT) continue;
		info[lc(p[1])] = n;
	}
	return info;
}

// epoch_of(v) — refill dates arrive either as an epoch or as YYYY-MM-DD. The
// dashboard renders epoch seconds, so normalise here (UTC midnight) rather than
// shipping two shapes to the frontend.
function epoch_of(v) {
	let t = trim(v);
	if (match(t, /^[0-9]+$/)) {
		let n = +t;
		return (n > 0 && n <= MAX_UI_INT) ? n : null;
	}
	let m = match(t, /^([0-9]{4})-([0-9]{2})-([0-9]{2})/);
	if (!m) return null;
	let y = +m[1], mo = +m[2], d = +m[3];
	if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
	// days-from-civil (Howard Hinnant's algorithm), UTC.
	let yy = (mo <= 2) ? y - 1 : y;
	let era = ((yy >= 0) ? yy : yy - 399) / 400;
	era = era - (era % 1);
	let yoe = yy - era * 400;
	let doy = ((153 * ((mo > 2) ? mo - 3 : mo + 9) + 2) / 5);
	doy = doy - (doy % 1) + d - 1;
	let doe = yoe * 365 + (yoe / 4 - (yoe / 4) % 1) - (yoe / 100 - (yoe / 100) % 1) + doy;
	return (era * 146097 + doe - 719468) * 86400;
}

// meta_kv(out, key, value) — ONE mapping table for both sources of metadata:
// the response headers and the body preamble. They carry identical keys, and
// two copies of this table would drift.
function meta_kv(out, key, val) {
	if (key === "subscription-userinfo") {
		let i = parse_userinfo(val);
		if (length(i)) out.userinfo = i;
	} else if (key === "profile-title") {
		let v = trim(maybe_b64(trim(val)));
		if (v !== "") out.title = clip(v, MAX_TITLE);
	} else if (key === "content-disposition") {
		// ucode's regex engine (POSIX/TRE) has no non-capturing (?:...) groups, so
		// capture the raw value then strip an optional RFC 5987 charset prefix
		// (UTF-8'') and surrounding quotes by hand.
		let fn = match(val, /[Ff]ilename\*?=[ \t]*"?([^";\r\n]+)"?/);
		if (fn) {
			let v = trim(fn[1]);
			let cs = match(v, /^[A-Za-z0-9-]+''(.*)$/);
			if (cs) v = trim(cs[1]);
			if (v !== "") out.fileName = clip(v, MAX_TITLE);
		}
	} else if (key === "profile-web-page-url") {
		let u = safe_url(val); if (u) out.webPageUrl = u;
	} else if (key === "support-url") {
		let u = safe_url(val); if (u) out.supportUrl = u;
	} else if (key === "announce-url") {
		let u = safe_url(val); if (u) out.announceUrl = u;
	} else if (key === "announce") {
		let v = trim(maybe_b64(trim(val)));
		if (v !== "") out.announce = clip(v, MAX_ANNOUNCE);
	} else if (key === "subscription-refill-date") {
		let e = epoch_of(val);
		if (e != null) out.refillDate = e;
	}
}

const META_KEYS_RE = /^([A-Za-z][A-Za-z0-9-]*):[ \t]*(.*)$/;

// parse_headers(hdr) — the curl -D dump. Tolerant: unknown lines are ignored, a
// garbage dump yields {}.
function parse_headers(hdr) {
	let out = {};
	if (hdr == null) return out;
	for (let line in split(hdr, "\n")) {
		let m = match(trim(line), META_KEYS_RE);
		if (!m) continue;
		meta_kv(out, lc(m[1]), m[2]);
	}
	// content-disposition's filename is the only title a lot of panels send;
	// profile-title (parsed above, order-independent) still wins.
	if (out.title == null && out.fileName != null) out.title = out.fileName;
	return out;
}

// preamble_meta(body) — the same keys, but carried INSIDE the body as leading
// `#`/`//` comment lines (first 20 lines only). Common with panels that cannot
// set custom headers on a CDN.
function preamble_meta(body) {
	let out = {};
	if (body == null) return out;
	let n = 0;
	for (let line in split(body, "\n")) {
		if (n++ >= 20) break;
		let t = trim(line);
		if (t === "") continue;
		let v;
		if (substr(t, 0, 2) === "//")     v = trim(substr(t, 2));
		else if (substr(t, 0, 1) === "#") v = trim(substr(t, 1));
		else continue;
		let m = match(v, META_KEYS_RE);
		if (!m) continue;
		meta_kv(out, lc(m[1]), m[2]);
	}
	return out;
}

// normalize_meta(raw) — the shape the dashboard consumes. `userinfo` is kept
// alongside it: sub_status's legacy consumers (and the .meta sidecar written by
// older builds) still speak that shape.
function normalize_meta(raw) {
	let out = {};
	for (let k in ["title", "webPageUrl", "supportUrl", "announce", "announceUrl",
	               "refillDate", "fileName"])
		if (raw[k] != null) out[k] = raw[k];
	let u = raw.userinfo;
	if (u != null) {
		out.userinfo = u;
		let up = +u.upload || 0, dn = +u.download || 0, total = +u.total || 0;
		let used = up + dn;
		out.traffic = {
			used: used, upload: up, download: dn, total: total,
			remaining: (total > used) ? total - used : 0,
			isUnlimited: !(total > 0),
		};
		if (+u.expire > 0) out.expire = +u.expire;
	}
	return out;
}

// -------------------------------------------------------------------- caches

function cache_paths(name) {
	return {
		txt:     `${CACHE_DIR}/sub_${name}.txt`,
		meta:    `${CACHE_DIR}/sub_${name}.meta`,
		stat:    `${CACHE_DIR}/sub_${name}.stat`,
		profile: `${CACHE_DIR}/sub_${name}.profile`,
		ua:      `${CACHE_DIR}/sub_${name}.ua`,
	};
}

function tmp_paths(name) {
	return {
		txt:  `${TMPDIR}/sub_${name}.txt`,
		meta: `${TMPDIR}/sub_${name}.meta`,
		stat: `${TMPDIR}/sub_${name}.stat`,
	};
}

// Progress side-car. rpcd's `refresh {async:true}` forks this file into the
// background and answers the browser immediately (a 6-subscription refresh over
// a slow link outlives ubus' request timeout), so this file is the ONLY thing
// the dashboard can poll to know where the run is.
const PROG_PATH = `${TMPDIR}/sub_progress.json`;
function prog_write(p) { write_atomic(PROG_PATH, sprintf("%J", p), 0o644); }

// sub_proxy — fetch THIS subscription through a proxy (curl -x). Validated, not
// escaped-and-hoped: the value crosses into curl's argv, and curl reads a
// scheme it does not know (e.g. `file://`) as a local read.
function proxy_of(cur, name) {
	let v = trim(helpers.uci_get_or_empty(cur, name, "sub_proxy"));
	if (v === "") return null;
	if (!match(v, /^(socks5h|socks5|socks4a|socks4|http|https):\/\/[A-Za-z0-9._~%@:-]+:[0-9]{1,5}$/)) {
		log_err(`fetch_subs: ${name} has an unusable sub_proxy, fetching direct`);
		return null;
	}
	return v;
}

function cache_dir_ensure() {
	let parent = replace(CACHE_DIR, /\/[^\/]+$/, "");
	if (parent !== CACHE_DIR && parent !== "") fs.mkdir(parent, 0o755);
	fs.mkdir(CACHE_DIR, 0o700);
	try { fs.chmod(CACHE_DIR, 0o700); } catch (_) {}
}

// C2: the cache belongs to a (url, user-agent, hwid) triple. Changing sub_url
// used to leave the OLD provider's nodes live until sub_interval expired —
// the config kept routing through servers the user had just replaced.
function profile_of(cur, name) {
	return helpers.uci_get_or_empty(cur, name, "sub_url") + "\n" +
	       helpers.uci_get_or_empty(cur, name, "sub_user_agent") + "\n" +
	       hwid_for(cur, name);
}

function purge(name) {
	let t = tmp_paths(name), c = cache_paths(name);
	for (let p in [t.txt, t.meta, t.stat, c.txt, c.meta, c.stat, c.profile, c.ua])
		helpers.unlink_quiet(p);
}

// restore(name, profile) — C1: repopulate tmpfs from flash. Only when the cached
// copy belongs to the CURRENT profile (C2) and tmpfs has nothing newer.
function restore(name, profile) {
	let t = tmp_paths(name), c = cache_paths(name);
	if (fs.stat(t.txt)) return false;
	let cp = _reader(c.profile);
	if (cp == null || trim(cp) !== trim(profile)) return false;
	let body = _reader(c.txt);
	if (body == null || body === "") return false;
	if (!write_atomic(t.txt, body, 0o600)) return false;
	for (let pair in [[c.meta, t.meta], [c.stat, t.stat]]) {
		let v = _reader(pair[0]);
		if (v != null && v !== "") write_atomic(pair[1], v, 0o600);
	}
	log(`restore: ${name} recovered from persistent cache`);
	return true;
}

function persist(name, profile, ua_id, body, meta_json, stat_json) {
	cache_dir_ensure();
	let c = cache_paths(name);
	write_atomic(c.txt, body, 0o600);
	write_atomic(c.profile, profile, 0o600);
	write_atomic(c.ua, ua_id, 0o600);
	if (meta_json != null) write_atomic(c.meta, meta_json, 0o600);
	else helpers.unlink_quiet(c.meta);
	if (stat_json != null) write_atomic(c.stat, stat_json, 0o600);
}

// ---------------------------------------------------------------------- lock

function lock_acquire() {
	fs.mkdir(TMPDIR, 0o755);
	if (fs.mkdir(LOCK_DIR, 0o700)) return true;
	let st = fs.stat(LOCK_DIR);
	if (st && (time() - st.mtime) > LOCK_STALE) {
		log_err("fetch_subs: breaking stale lock");
		try { fs.rmdir(LOCK_DIR); } catch (_) {}
		return fs.mkdir(LOCK_DIR, 0o700) ? true : false;
	}
	return false;
}

function lock_release() { try { fs.rmdir(LOCK_DIR); } catch (_) {} }

// --------------------------------------------------------------------- fetch

// gunzip_if_needed(path, raw) — F3. Some panels serve a gzip BODY (not a
// Content-Encoding, which curl would handle). gzip is optional on OpenWrt, so
// probe for it: without it we simply cannot read the body, which is a clean
// "no nodes" rather than a crash.
function gunzip_if_needed(path, raw) {
	if (raw == null || length(raw) < 2) return raw;
	if (!(ord(raw, 0) === 0x1f && ord(raw, 1) === 0x8b)) return raw;
	if (!have_bin("gzip")) {
		log_err("fetch_subs: gzip body but no gzip binary available");
		return raw;
	}
	let p = null;
	try { p = fs.popen("gzip -dc < " + helpers.sq(path) + " 2>/dev/null", "r"); } catch (_) { return raw; }
	if (!p) return raw;
	let out = null;
	try { out = p.read("all"); } catch (_) { out = null; }
	try { p.close(); } catch (_) {}
	return (out != null && length(out)) ? out : raw;
}

function sleep_s(n) {
	if (!(n > 0)) return;
	try { system(["/bin/sh", "-c", sprintf("sleep %d", n)]); } catch (_) {}
}

// download(job) — D1: up to RETRIES attempts, RETRY_SLEEP apart. curl exit 5/6
// is a DNS failure: the name does not resolve, and it will not resolve two
// seconds later either — retrying only delays the whole refresh cycle.
function download(job) {
	for (let i = 0; i < RETRIES; i++) {
		helpers.unlink_quiet(job.body_path);
		helpers.unlink_quiet(job.hdr_path);
		_fetcher([job]);
		let rc = job.rc ?? 0;
		let st = fs.stat(job.body_path);
		if (st && st.size > 0) return 0;
		if (rc === 5 || rc === 6) {
			log_err(`fetch_subs: ${job.name} DNS failure (curl ${rc}); not retrying`);
			return rc;
		}
		if (i < RETRIES - 1) sleep_s(RETRY_SLEEP);
	}
	return job.rc ?? 1;
}

// canon(v) — key-order-independent rendering of a JSON value. C3 compares node
// SETS semantically; a provider re-serialising the same node with its keys in a
// different order must not read as "changed" and cost every user their
// connections.
function canon(v) {
	let t = type(v);
	if (t === "object") {
		let ks = sort(keys(v));
		let parts = [];
		for (let k in ks) push(parts, sprintf("%J", k) + ":" + canon(v[k]));
		return "{" + join(",", parts) + "}";
	}
	if (t === "array") {
		let parts = [];
		for (let e in v) push(parts, canon(e));
		return "[" + join(",", parts) + "]";
	}
	return sprintf("%J", v);
}

// group_sig(gr) — a group's contribution to signature(): type+name+sorted
// members. Anything else the provider set (url/interval/tolerance/default) is
// display-only and does not gate a reload.
function group_sig(gr) {
	let g = gr.group ?? {};
	let members = (type(g.members) === "array") ? g.members : [];
	return "G|" + (g.type ?? "") + "|" + (gr.name ?? "") + "|" + join(",", sort(members));
}

// signature(nodes, groups) — the semantic identity of a node set: sorted
// canonical outbounds plus their display names, insensitive to ordering, plus
// (B1) a sorted digest of the provider's groups. A body with no groups
// (`groups` null/empty, the case for every subscription before B1) yields the
// exact same string as before — no spurious reload for existing content.
function signature(nodes, groups) {
	let sigs = [];
	for (let n in nodes)
		push(sigs, canon(n.outbound) + "|" + (n.display_name ?? ""));
	for (let gr in (groups ?? []))
		push(sigs, group_sig(gr));
	return join("\n", sort(sigs));
}

function signature_of_file(path) {
	let body = _reader(path);
	if (body == null) return null;
	let nodes = [], groups = [];
	for (let line in split(body, "\n")) {
		let n = subformat.parse_node(line);
		if (n) { push(nodes, n); continue; }
		let g = subformat.parse_group(line);
		if (g) push(groups, g);
	}
	return signature(nodes, groups);
}

// ua_candidates(cur, name) — rotation order. The manually chosen profile goes
// first; then the UA that WORKED last time (cached on flash); then the rest.
// A panel that answers HTTP 200 with an HTML "install the app" page for one UA
// and a real config for another is the common case, so we keep going until a
// body actually parses into nodes — not merely until curl exits 0.
function ua_candidates(cur, name) {
	let out = [];
	function add(id) {
		if (id == null || id === "") return;
		for (let e in out) if (e === id) return;
		push(out, id);
	}
	add(helpers.uci_get_or_empty(cur, name, "sub_user_agent"));
	let cached = _reader(cache_paths(name).ua);
	if (cached != null) add(trim(cached));
	for (let id in UA_ORDER) add(id);
	return out;
}

// fetch_one(cur, name, timeout) -> { ok, changed }
function fetch_one(cur, name, timeout) {
	let url = helpers.uci_get_or_empty(cur, name, "sub_url");
	if (url === "") {
		log_err(`fetch_subs: ${name} has no sub_url, skipping`);
		return { ok: false, changed: false };
	}
	let t = tmp_paths(name);
	let profile = profile_of(cur, name);
	let cached_profile = _reader(cache_paths(name).profile);

	// C2: a changed profile means everything we hold for this section describes a
	// DIFFERENT subscription. Drop it before fetching — keeping it would leave the
	// old provider's nodes live if the new fetch fails.
	if (cached_profile != null && trim(cached_profile) !== trim(profile)) {
		log(`fetch_subs: ${name} profile changed, invalidating cache`);
		purge(name);
	}

	let hwid = hwid_for(cur, name);
	let headers = provider_headers(hwid);
	let body_path = `${TMPDIR}/sub_${name}.raw`;
	let hdr_path  = `${TMPDIR}/sub_${name}.hdr`;

	let proxy = proxy_of(cur, name);
	let parsed = null, ua_used = null, raw = null, hdr_raw = "";
	for (let ua_id in ua_candidates(cur, name)) {
		let job = {
			name: name, url: url, ua: ua_of(ua_id), headers: headers, proxy: proxy,
			body_path: body_path, hdr_path: hdr_path, opts: { timeout: timeout },
		};
		let rc = download(job);
		let st = fs.stat(body_path);
		if (!st || st.size === 0) {
			// The server did not ANSWER (DNS, refused, timeout). Rotating the UA
			// addresses what a panel SERVES, not whether it is reachable — trying
			// five more UAs against a dead host only burns the boot fetch budget.
			log_err(`fetch_subs: ${name} download failed (curl ${rc})`);
			break;
		}
		if (st.size > MAX_BODY) {
			log_err(`fetch_subs: ${name} body ${st.size} bytes exceeds ${MAX_BODY}, rejecting`);
			break;
		}
		let b = _reader(body_path);
		b = gunzip_if_needed(body_path, b);
		if (b == null || length(b) === 0) continue;

		let res = null;
		try { res = subformat.parse_body(b, 0); } catch (e) {
			log_err(`fetch_subs: ${name} parse error: ${e}`);
			res = null;
		}
		// U1: HTTP 200 is NOT success. A panel's HTML stub parses to zero nodes —
		// rotate to the next UA rather than declaring victory on an empty list.
		if (res == null || !length(res.nodes)) continue;
		parsed = res;
		ua_used = ua_id;
		raw = b;
		hdr_raw = _reader(hdr_path) ?? "";
		break;
	}
	helpers.unlink_quiet(body_path);
	helpers.unlink_quiet(hdr_path);

	if (parsed == null) {
		// SEC-7: this fetch produced no valid meta, so a stale sidecar from a prior
		// fetch (traffic/expiry/title) must be dropped — otherwise the dashboard
		// renders stale quota indefinitely for a now-failing subscription.
		log_err(`fetch_subs: no usable subscription content for ${name}`);
		helpers.unlink_quiet(t.meta);
		helpers.unlink_quiet(t.stat);
		return { ok: false, changed: false };
	}

	let lines = [];
	for (let n in parsed.nodes) push(lines, subformat.encode_node(n));
	for (let gr in (parsed.groups ?? [])) push(lines, subformat.encode_group(gr));
	let body = join("\n", lines) + "\n";

	// C3: compare BEFORE overwriting. reload = stop+start = every connection
	// dropped; doing that every 15 minutes for a subscription that did not change
	// is the single most visible thing this file used to get wrong.
	let old_sig = signature_of_file(t.txt);
	let new_sig = signature(parsed.nodes, parsed.groups);
	let changed = (old_sig !== new_sig);

	if (!write_atomic(t.txt, body, 0o600)) {
		log_err(`fetch_subs: cannot write ${t.txt}`);
		return { ok: false, changed: false };
	}

	// Headers OVERRIDE the body preamble (the spec's precedence): a CDN-cached
	// body can carry a stale announce while the header set is live.
	let rawmeta = preamble_meta(raw);
	let hdrmeta = parse_headers(hdr_raw);
	for (let k in hdrmeta) rawmeta[k] = hdrmeta[k];
	let meta_json = null;
	if (length(rawmeta)) {
		meta_json = sprintf("%J", normalize_meta(rawmeta));
		write_atomic(t.meta, meta_json, 0o600);
	} else {
		helpers.unlink_quiet(t.meta);
	}

	// F5: `skipped` is how the user learns why 50 advertised nodes arrived as 30.
	let stat_json = sprintf("%J", {
		skipped: parsed.skipped, format: parsed.format, user_agent: ua_of(ua_used),
	});
	write_atomic(t.stat, stat_json, 0o600);

	if (helpers.uci_get_or_empty(cur, name, "sub_cache_persist") !== "0")
		persist(name, profile, ua_used ?? "", body, meta_json, stat_json);
	else {
		// persist OFF promises node passwords stay off flash — so a copy a PRIOR
		// persist-on fetch left behind must be REMOVED, not merely skipped, or the
		// credential sits on flash forever. Only the flash files (not purge(),
		// which also drops the tmpfs working copy sing-box still needs).
		let c = cache_paths(name);
		for (let p in [c.txt, c.profile, c.ua, c.meta, c.stat]) helpers.unlink_quiet(p);
		log(sprintf("fetch_subs: %s cache-persist off (tmpfs only)", name));
	}

	log(sprintf("fetch_subs: %s -> %s (%d nodes, %d skipped, format=%s, changed=%s)",
	            name, t.txt, length(parsed.nodes), parsed.skipped, parsed.format,
	            changed ? "yes" : "no"));
	return { ok: true, changed: changed };
}

// cmd_fetch_subs(cur, only) -> number of subscriptions whose node set CHANGED
// (-1 when another refresh holds the lock).
function cmd_fetch_subs(cur, only) {
	fs.mkdir(TMPDIR, 0o755);

	let names = helpers.sections_of_kind(cur, "outbound", "type", "subscription");
	if (!length(names)) {
		log_err("fetch_subs: no subscription outbounds configured");
		return 0;
	}

	if (!lock_acquire()) {
		log_err("fetch_subs: another refresh is running, skipping");
		return -1;
	}

	let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
	let timeout = boot ? 5 : 15;
	let changed = 0;

	let todo = [];
	for (let name in names) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_subs: ${name} disabled, skipping`);
			continue;
		}
		if (only != null && name !== only) continue;
		push(todo, name);
	}

	let prog = { running: 1, total: length(todo), done: 0, current: "",
	             started: time(), finished: 0, results: {} };
	prog_write(prog);

	for (let name in todo) {
		prog.current = name;
		prog_write(prog);

		// C1: restore the flash copy FIRST. init.d runs `fetch-subs` before
		// generate.uc and waits for it, so a boot with no network still hands
		// generate.uc the last known good node list instead of nothing.
		if (helpers.uci_get_or_empty(cur, name, "sub_cache_persist") !== "0")
			restore(name, profile_of(cur, name));

		let r;
		try { r = fetch_one(cur, name, timeout); }
		catch (e) { log_err(`fetch_subs: ${name} failed: ${e}`); r = { changed: false }; }
		if (r.changed) changed++;

		prog.results[name] = r.ok ? "ok" : "error";
		prog.done++;
		prog.current = "";
		prog_write(prog);
	}

	prog.running = 0;
	prog.finished = time();
	prog_write(prog);

	lock_release();
	return changed;
}

function any_subs_stale(cur, force, only) {
	for (let name in helpers.sections_of_kind(cur, "outbound", "type", "subscription")) {
		if (only != null && name !== only) continue;
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") continue;
		// C2: a profile change is staleness, regardless of mtime.
		let cp = _reader(cache_paths(name).profile);
		if (cp != null && trim(cp) !== trim(profile_of(cur, name))) return true;
		let iv = +helpers.uci_get_or_empty(cur, name, "sub_interval");
		// !(iv > 0) catches NaN/0/negatives — +"abc" yields NaN and `iv === 0`
		// was false, so iv stayed NaN and is_stale's `>= NaN` was always false,
		// silently disabling refresh.
		if (!(iv > 0)) iv = 3600;
		if (helpers.is_stale(`${TMPDIR}/sub_${name}.txt`, iv, force)) return true;
	}
	return false;
}

// cmd_sub_status(cur) — pure read aggregation for the dashboard. No network,
// no UCI writes.
function cmd_sub_status(cur) {
	let out = [];
	for (let name in helpers.sections_of_kind(cur, "outbound", "type", "subscription")) {
		let enabled = (helpers.uci_get_or_empty(cur, name, "enabled") === "0") ? "0" : "1";
		let t = tmp_paths(name);
		let last_update = null, node_count = 0;
		let st = fs.stat(t.txt);
		if (st && st.type === "file") {
			last_update = st.mtime;
			let body = _reader(t.txt) ?? "";
			for (let line in split(body, "\n")) if (trim(line) !== "") node_count++;
		}
		let title = null, userinfo = null, metadata = null;
		let mst = fs.stat(t.meta);
		if (mst && mst.type === "file") {
			let parsed = null;
			try { parsed = json(_reader(t.meta) ?? ""); } catch (_) {}
			if (type(parsed) === "object") {
				metadata = parsed;
				title = parsed.title ?? null;
				userinfo = parsed.userinfo ?? null;
			}
		}
		let skipped = 0, format = null;
		let sst = fs.stat(t.stat);
		if (sst && sst.type === "file") {
			let parsed = null;
			try { parsed = json(_reader(t.stat) ?? ""); } catch (_) {}
			if (type(parsed) === "object") {
				skipped = +parsed.skipped || 0;
				format = parsed.format ?? null;
			}
		}
		push(out, { name: name, enabled: enabled,
		            last_update: last_update, node_count: node_count,
		            skipped: skipped, format: format,
		            title: title, userinfo: userinfo, metadata: metadata });
	}
	return out;
}

// subs_refresh_allowed(cur, force) — apply the subscriptions.auto_update gate.
// UI refresh always passes force=true (rpcd appends "force") → never gated.
// Cron calls non-force; auto_update='0' suppresses the cron subs refresh.
function subs_refresh_allowed(cur, force) {
	if (force) return true;
	return helpers.uci_get_or_empty(cur, "subscriptions", "auto_update") !== "0";
}

function cmd_refresh(cur, force, name) {
	let no_reload = getenv("SINGBOX_NO_RELOAD") === "1";
	if (!subs_refresh_allowed(cur, force)) return 0;
	if (any_subs_stale(cur, force, name)) {
		let changed = cmd_fetch_subs(cur, name);
		// C3: reload only when the node set really moved. C4: `changed < 0` means
		// another refresh holds the lock — it will do the reload itself.
		if (changed > 0 && !no_reload) system([SINGBOX_INITD, "reload"]);
	}
	return 0;
}

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
fs.mkdir(TMPDIR, 0o755);

// When run as a CLI (init.d / cron) ARGV carries the subcommand. When the
// file is require()d as a module (tests), ARGV is empty — skip the dispatch
// and just export the pure/injectable surface, mirroring how lib modules
// return {} at the bottom.
if (length(ARGV)) {
	let argv = ARGV;
	let sub = argv[0] || "";
	switch (sub) {
	case "fetch-subs":  cmd_fetch_subs(cur, argv[1]); break;
	case "refresh":     cmd_refresh(cur, argv[1] === "force", argv[2]); break;
	case "sub-status":  printf("%J\n", cmd_sub_status(cur)); break;
	default:
		log_err("usage: subscription.uc {fetch-subs|refresh [force] [name]|sub-status}");
		exit(2);
	}
}

return {
	is_stale,
	_parse_headers_for_test: parse_headers,
	_preamble_meta_for_test: preamble_meta,
	_normalize_meta_for_test: normalize_meta,
	_signature_for_test: signature,
	_ua_of_for_test: ua_of,
	_ua_candidates_for_test: ua_candidates,
	_proxy_of_for_test: proxy_of,
	_set_io_for_test,
	_set_fetcher_for_test,
	_fetcher_real_for_test: function(jobs) { return _fetcher(jobs); },
	_read_raw_for_test,
	_cmd_fetch_subs_for_test: function(cur, only) { return cmd_fetch_subs(cur, only); },
	_cmd_sub_status_for_test: function(cur) { return cmd_sub_status(cur); },
	_cmd_refresh_for_test: function(cur, force, name) { return cmd_refresh(cur, force, name); },
	_any_subs_stale_for_test: function(cur, force, only) { return any_subs_stale(cur, force, only); },
	_subs_refresh_allowed_for_test: function(cur, force) { return subs_refresh_allowed(cur, force); },
};
