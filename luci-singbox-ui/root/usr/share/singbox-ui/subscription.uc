#!/usr/bin/ucode
// Subscription fetcher and refresh driver (subscriptions only).
// Subcommands:
//   fetch-subs                              — download all subscription outbounds
//   refresh [force] [name]                  — refresh stale subscriptions
//   sub-status                              — print subscription status JSON
//
// Env overrides (used by tests):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)
//   UCI_CONFIG_DIR (honoured by require("uci").cursor)
//   SINGBOX_NO_RELOAD=1 — refresh skips the init.d reload (tests)
//   SINGBOX_INITD  (default /etc/init.d/singbox-ui) — init.d path for reload (tests)

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
// Cap subscription bodies so a hostile or runaway source cannot OOM a 128–256 MB
// router. cmd_fetch_subs enforces MAX_BODY via a post-download fs.stat() guard.
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB

// init.d reload seam. reload is stop+start (sing-box has no signal reload) —
// used to apply new subscription config after fetching.
const SINGBOX_INITD = getenv("SINGBOX_INITD") || "/etc/init.d/singbox-ui";

// curl binary seam (tests override via env). Subscriptions are always fetched
// directly via curl — no proxy/outbound routing. curl has its own --max-time so
// the external `timeout` wrapper is not needed here.
const CURL = getenv("CURL") || "/usr/bin/curl";
// Default browser UA when a subscription leaves sub_user_agent empty.
const DEFAULT_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                   "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

// SEC-6: single source of truth for the share-link schemes we actually parse.
// This list is kept aligned with lib/sharelink.uc::parse_proxy_url's dispatch
// (vless/vmess/ss/trojan/hy2/hysteria2). Two consumers used to carry divergent
// inline scheme sets — try_b64_decode's decode-trigger whitelist once included
// `http`/`https`, contradicting the anti-false-positive heuristic it documents
// (a plaintext error page line `visit https://…/help` would falsely trigger a
// base64 decode). The line-scan stays deliberately generic (any `scheme://`,
// with parse_proxy_url rejecting unsupported schemes downstream); only the
// decode TRIGGER is narrowed to schemes we can actually parse.
const PROXY_SCHEME_RE = /^(vmess|vless|ss|trojan|hy2|hysteria2):\/\//;

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");

// Two channels: log() is ops-info, log_err() is errors. They both write to
// stderr (init.d/cron route it to syslog) but log_err tags severity so an
// operator reading logread can tell the two apart — they used to be byte
// identical, an illusion of separate channels.
function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn("error: " + msg + "\n"); }

// SEC-9: best-effort unlink that never throws. ucode's fs.unlink can throw on
// some error conditions; an unguarded throw inside a per-job loop would abort
// processing of every REMAINING job in the refresh cycle (one bad subscription
// poisons the rest). Several in-loop unlinks here were bare while adjacent ones
// were already try-wrapped — that ad-hoc asymmetry is the latent footgun. Route
// every in-loop unlink through this helper so a single failure stays local.
function unlink_quiet(p) { try { fs.unlink(p); } catch (_) {} }

// I/O seams — overridable for tests, mirroring log._set_logger_for_test.
// _reader(path) returns the raw body string (or null); _fetcher(jobs) runs
// one `curl` per job sequentially, fetching directly. BOTH `let` bindings are
// declared here, BEFORE the setter helpers below close over and assign to
// them — a forward reference would hit the temporal dead zone and throw at
// call time.
let _reader = function(path) {
	let fd = fs.open(path, "r");
	if (!fd) return null;
	let body;
	try { body = fd.read("all"); } catch (e) { body = null; }
	fd.close();
	return body;
};

// _fetcher(jobs) — for each job runs `curl -fsSL --max-time <to> -A <ua>
// -D <hdr_path> -o <body_path> <url>`, downloading directly (no proxy). curl
// writes the body to body_path and the response headers to hdr_path. All argv
// is shell-quoted via helpers.sq() so a hostile url/ua cannot break the command.
let _fetcher = function(jobs) {
	if (!length(jobs)) return;
	for (let j in jobs) {
		let ua = (j.ua != null && j.ua !== "") ? j.ua : DEFAULT_UA;
		let to = (j.opts && j.opts.timeout) ? j.opts.timeout : 15;
		let argv = [ CURL, "-fsSL", "--max-time", sprintf("%d", to),
		             "-A", ua, "-D", j.hdr_path, "-o", j.body_path, j.url ];
		let quoted = [];
		for (let a in argv) push(quoted, helpers.sq(a));
		let line = join(" ", quoted) + " >/dev/null 2>&1";
		try { system(["/bin/sh", "-c", line]); } catch (_) {}
	}
};

// _set_io_for_test(fetcher, reader) — install mock I/O. Either arg may be
// null to keep the current implementation. Declared AFTER _fetcher/_reader
// so both targets are already in scope when this assigns to them.
function _set_io_for_test(fetcher, reader) {
	if (fetcher != null) _fetcher = fetcher;
	if (reader != null)  _reader  = reader;
}

// _set_fetcher_for_test(fn) — dedicated seam to inject a mock fetcher.
function _set_fetcher_for_test(fn) { _fetcher = fn; }

// _read_raw_for_test(path) — thin wrapper so a test can verify the reader
// seam without a uci cursor.
function _read_raw_for_test(path) { return _reader(path); }

// Subscription bodies are usually base64-encoded plaintext containing one
// proxy URL per line; some servers return plaintext directly. Decode only
// when the decoded payload looks like proxy URLs — strict heuristic: at
// least one decoded LINE must start with a recognized share-link scheme.
// The old "contains '://'" check tripped on plaintext error pages like
// "visit https://example.com/help" and silently mangled the body.
function try_b64_decode(s) {
	let dec = null;
	try { dec = b64dec(s); } catch (e) { /* invalid base64 */ }
	if (dec == null || !length(dec)) return s;
	let lines = split(dec, "\n");
	for (let l in lines) {
		let t = lc(trim(l));
		// SEC-6: trigger on PROXY_SCHEME_RE only (schemes parse_proxy_url
		// supports), NOT a generic scheme set — http/https are excluded so a
		// base64-encoded plaintext page does not get treated as proxy content.
		if (match(t, PROXY_SCHEME_RE))
			return dec;
	}
	return s;
}

// write_atomic(path, body) — write body to a sibling tmp file, flush via
// close, then fs.rename over `path`. Guarantees sing-box never reads a
// half-written sub_<name>.txt and never leaks the fd on a write exception.
// Mirrors generate.uc::publish_atomic. Returns true on success.
function write_atomic(path, body) {
	let tmp = sprintf("%s.tmp.%d", path, time());
	let f = fs.open(tmp, "w");
	if (!f) { log_err(`write_atomic: cannot open ${tmp}`); return false; }
	let ok = true;
	try { f.write(body); } catch (e) { ok = false; }
	f.close();
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

// parse_headers(hdr) -> { userinfo?:{upload,download,total,expire}, title? }.
// Reads the curl -D header dump. Tolerant: missing fields are simply omitted,
// a garbage dump yields {}. subscription-userinfo is a ';'-separated k=v list;
// title comes from content-disposition filename or a profile-title header
// (base64:-prefixed values are decoded).
function parse_headers(hdr) {
	let out = {};
	if (hdr == null) return out;
	let info = null, title = null;
	for (let line in split(hdr, "\n")) {
		let l = trim(line);
		let ui = match(l, /^[Ss]ubscription-[Uu]serinfo:[ \t]*(.*)$/);
		if (ui) {
			info = {};
			for (let kv in split(ui[1], ";")) {
				let p = match(trim(kv), /^([A-Za-z_]+)=([0-9]+)$/);
				if (p) info[lc(p[1])] = +p[2];
			}
		}
		if (index(lc(l), "content-disposition") === 0) {
			// ucode's regex engine (POSIX/TRE) has no non-capturing (?:...)
			// groups, so capture the raw value then strip an optional
			// RFC 5987 charset prefix (UTF-8'') and surrounding quotes by hand.
			let fn = match(l, /[Ff]ilename\*?=[ \t]*"?([^";\r\n]+)"?/);
			if (fn) {
				let v = trim(fn[1]);
				let cs = match(v, /^[A-Za-z0-9-]+''(.*)$/);
				if (cs) v = trim(cs[1]);
				title = v;
			}
		}
		let pt = match(l, /^[Pp]rofile-[Tt]itle:[ \t]*(.*)$/);
		if (pt) {
			let v = trim(pt[1]);
			let b = match(v, /^base64:(.*)$/);
			if (b) {
				// SEC-5: distinguish a decode FAILURE from an empty (but valid)
				// decode. b64dec returns null on malformed input (and never
				// throws here), but try-wrap it anyway in case a future runtime
				// throws. On ANY successful decode (even "") honour the decoded
				// value; only a hard failure falls back to the raw payload — and
				// then WITHOUT the "base64:" prefix, so the dashboard never
				// renders a literal "base64:..." title.
				let dec = null;
				try { dec = b64dec(trim(b[1])); } catch (_) {}
				v = (dec != null) ? dec : trim(b[1]);
			}
			title = v;
		}
	}
	if (info != null) out.userinfo = info;
	if (title != null && title !== "") out.title = title;
	return out;
}

function cmd_fetch_subs(cur, only) {
	// Ensure TMPDIR exists whether invoked via CLI (module-level mkdir above)
	// or via the test wrapper (_cmd_fetch_subs_for_test) which require()s the
	// module, bypassing the ARGV-gated module-level fs.mkdir call.
	fs.mkdir(TMPDIR, 0o755);

	let names = helpers.sections_of_kind(cur, "outbound", "type", "subscription");
	if (!length(names)) {
		log_err("fetch_subs: no subscription outbounds configured");
		return 0;
	}

	let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
	let timeout = boot ? 5 : 15;

	// Step 1: build one job per subscription. Each job carries the url, the
	// per-subscription User-Agent, and the body/header output paths; curl
	// fetches the url directly (no proxy routing).
	let jobs = [];
	for (let name in names) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_subs: ${name} disabled, skipping`);
			continue;
		}
		if (only != null && name !== only) continue;
		let url = helpers.uci_get_or_empty(cur, name, "sub_url");
		if (url === "") {
			log_err(`fetch_subs: ${name} has no sub_url, skipping`);
			continue;
		}
		let ua = helpers.uci_get_or_empty(cur, name, "sub_user_agent");
		let body_path = `${TMPDIR}/sub_${name}.raw`;
		let hdr_path  = `${TMPDIR}/sub_${name}.hdr`;
		let out_path  = `${TMPDIR}/sub_${name}.txt`;
		push(jobs, {
			name: name, body_path: body_path, hdr_path: hdr_path,
			out_path: out_path, url: url, ua: ua,
			opts: { timeout: timeout },
		});
	}

	// Step 2: fetch each subscription directly via curl.
	_fetcher(jobs);

	// Step 3: parse each result; on failure, leave existing out_path alone.
	for (let m in jobs) {
		let st = fs.stat(m.body_path);
		if (!st || st.size === 0) {
			log_err(`fetch_subs: download failed for ${m.name}`);
			unlink_quiet(m.body_path);
			unlink_quiet(m.hdr_path);
			continue;
		}
		if (st.size > MAX_BODY) {
			log_err(`fetch_subs: ${m.name} body ${st.size} bytes exceeds ${MAX_BODY}, rejecting`);
			unlink_quiet(m.body_path);
			unlink_quiet(m.hdr_path);
			continue;
		}

		let raw = _reader(m.body_path) ?? "";
		unlink_quiet(m.body_path);
		if (length(raw) === 0) {
			log_err(`fetch_subs: empty body for ${m.name}`);
			unlink_quiet(m.hdr_path);
			continue;
		}

		// try_b64_decode returns either the decoded blob (scheme-bearing
		// base64) or the original plaintext. The line scan stays generic (any
		// `scheme://`); parse_proxy_url rejects unsupported schemes downstream.
		let body = try_b64_decode(raw);
		let urls = [];
		for (let line in split(body, "\n")) {
			let t = trim(line);
			if (t !== "" && match(lc(t), /^[a-z][a-z0-9+.-]*:\/\//))
				push(urls, t);
		}
		if (!length(urls)) {
			// SEC-6: log a truncated sample of the (post-decode) body so the
			// operator can distinguish "unsupported scheme / wrong format" from
			// "garbage body" — both previously surfaced the same opaque message.
			let sample = trim(substr(body, 0, 120));
			sample = replace(sample, /[\r\n]+/g, " ");
			log_err(`fetch_subs: no valid proxy URL in response for ${m.name} (body starts: ${sample})`);
			unlink_quiet(m.hdr_path);
			continue;
		}

		if (!write_atomic(m.out_path, join("\n", urls) + "\n")) {
			log_err(`fetch_subs: cannot write ${m.out_path}`);
			unlink_quiet(m.hdr_path);
			continue;
		}
		log(`fetch_subs: ${m.name} -> ${m.out_path} (${length(urls)} urls)`);
		let hdr_raw = _reader(m.hdr_path) ?? "";
		let meta = parse_headers(hdr_raw);
		let meta_path = `${TMPDIR}/sub_${m.name}.meta`;
		if (length(meta)) {
			write_atomic(meta_path, sprintf("%J", meta));
		} else {
			// SEC-7: a prior fetch may have written meta (traffic/expiry/title)
			// that THIS response no longer carries (server stopped sending the
			// headers, or a different mirror). Drop the stale sidecar so the
			// dashboard reflects the current response instead of indefinitely
			// showing an expiry/quota that no longer applies. Mirrors the
			// unconditional .hdr cleanup just below.
			unlink_quiet(meta_path);
		}
		unlink_quiet(m.hdr_path);
	}
	return 0;
}

// is_stale(path, interval_s, force) -> bool. Missing file / zero interval / no
// interval => stale.
function is_stale(path, interval_s, force) {
	if (force) return true;
	let st = fs.stat(path);
	if (!st) return true;
	if (interval_s == null || interval_s === 0) return true;
	return (time() - st.mtime) >= interval_s;
}

function any_subs_stale(cur, force, only) {
	for (let name in helpers.sections_of_kind(cur, "outbound", "type", "subscription")) {
		if (only != null && name !== only) continue;
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") continue;
		let iv = +helpers.uci_get_or_empty(cur, name, "sub_interval");
		// !(iv > 0) catches NaN/0/negatives — +"abc" yields NaN and `iv === 0`
		// was false, so iv stayed NaN and is_stale's `>= NaN` was always false,
		// silently disabling refresh.
		if (!(iv > 0)) iv = 3600;
		if (is_stale(`${TMPDIR}/sub_${name}.txt`, iv, force)) return true;
	}
	return false;
}

// cmd_sub_status(cur) — pure read aggregation for the dashboard. For every
// type=subscription outbound: its enabled flag, the mtime of its fetched
// sub_<name>.txt (last_update, null if never fetched), and node_count (number of
// non-empty lines in that file). No network, no UCI writes.
function cmd_sub_status(cur) {
	let out = [];
	for (let name in helpers.sections_of_kind(cur, "outbound", "type", "subscription")) {
		let enabled = (helpers.uci_get_or_empty(cur, name, "enabled") === "0") ? "0" : "1";
		let path = `${TMPDIR}/sub_${name}.txt`;
		let last_update = null, node_count = 0;
		let st = fs.stat(path);
		if (st && st.type === "file") {
			last_update = st.mtime;
			let body = "";
			try { let f = fs.open(path, "r"); if (f) { body = f.read("all") || ""; f.close(); } } catch (_) {}
			for (let line in split(body, "\n")) if (trim(line) !== "") node_count++;
		}
		let title = null, userinfo = null;
		let mp = `${TMPDIR}/sub_${name}.meta`;
		let mst = fs.stat(mp);
		if (mst && mst.type === "file") {
			let mraw = _reader(mp) ?? "";
			let parsed = null;
			try { parsed = json(mraw); } catch (_) {}
			if (type(parsed) === "object") {
				title = parsed.title ?? null;
				userinfo = parsed.userinfo ?? null;
			}
		}
		push(out, { name: name, enabled: enabled,
		            last_update: last_update, node_count: node_count,
		            title: title, userinfo: userinfo });
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
		cmd_fetch_subs(cur, name);
		if (!no_reload) system([SINGBOX_INITD, "reload"]);
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
	case "fetch-subs":  cmd_fetch_subs(cur); break;
	case "refresh":     cmd_refresh(cur, argv[1] === "force", argv[2]); break;
	case "sub-status":  printf("%J\n", cmd_sub_status(cur)); break;
	default:
		log_err("usage: subscription.uc {fetch-subs|refresh [force] [name]|sub-status}");
		exit(2);
	}
}

return {
	try_b64_decode,
	is_stale,
	_parse_headers_for_test: parse_headers,
	_set_io_for_test,
	_set_fetcher_for_test,
	_fetcher_real_for_test: function(jobs) { return _fetcher(jobs); },
	_read_raw_for_test,
	_cmd_fetch_subs_for_test: function(cur) { return cmd_fetch_subs(cur); },
	_cmd_sub_status_for_test: function(cur) { return cmd_sub_status(cur); },
	_any_subs_stale_for_test: function(cur, force, only) { return any_subs_stale(cur, force, only); },
	_subs_refresh_allowed_for_test: function(cur, force) { return subs_refresh_allowed(cur, force); },
};
