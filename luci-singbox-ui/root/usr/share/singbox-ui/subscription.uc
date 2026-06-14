#!/usr/bin/ucode
// Subscription fetcher and refresh driver (subscriptions only).
// Subcommands:
//   fetch-subs                              — download all subscription outbounds
//   refresh [force] [name]                  — refresh stale subscriptions
//   sub-status                              — print subscription status JSON
//
// Env overrides (used by tests):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)
//   SINGBOX        (default /usr/bin/sing-box)
//   UCI_CONFIG_DIR (honoured by require("uci").cursor)
//   SINGBOX_NO_RELOAD=1 — refresh skips the init.d reload (tests)
//   SINGBOX_INITD  (default /etc/init.d/singbox-ui) — init.d path for reload (tests)

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
const SINGBOX    = getenv("SINGBOX")        || "/usr/bin/sing-box";
// Cap subscription bodies so a hostile or runaway source cannot OOM a 128–256 MB
// router. cmd_fetch_subs enforces MAX_BODY via a post-download fs.stat() guard.
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB

// init.d reload seam. reload is stop+start (sing-box has no signal reload) —
// used to apply new subscription config after fetching.
const SINGBOX_INITD = getenv("SINGBOX_INITD") || "/etc/init.d/singbox-ui";

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");
let ob_mod = require("outbound");

// Two channels: log() is ops-info, log_err() is errors. They both write to
// stderr (init.d/cron route it to syslog) but log_err tags severity so an
// operator reading logread can tell the two apart — they used to be byte
// identical, an illusion of separate channels.
function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn("error: " + msg + "\n"); }

// I/O seams — overridable for tests, mirroring log._set_logger_for_test.
// _reader(path) returns the raw body string (or null); _fetcher(jobs) runs
// one `sing-box tools fetch` per job sequentially. BOTH `let` bindings are
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

// _fetcher(jobs) — for each job runs `sing-box tools fetch -c <cfg> -o <via>
// <url>` capturing stdout to job.outpath. The ephemeral cfg (job.cfg_json) is
// written to a sibling temp file. `timeout` is optional on stock OpenWrt (not a
// busybox applet) — guarded with `command -v`, mirroring nftables.uc's apply.
let _fetcher = function(jobs) {
	if (!length(jobs)) return;
	let has_timeout = (system(["/bin/sh", "-c", "command -v timeout >/dev/null 2>&1"]) === 0);
	for (let j in jobs) {
		let cfgpath = sprintf("%s.cfg", j.outpath);
		let cf = fs.open(cfgpath, "w");
		if (!cf) { log_err(`fetch: cannot write cfg for ${j.name}`); continue; }
		try { cf.write(j.cfg_json); } catch (_) {}
		cf.close();
		let argv = [ SINGBOX, "tools", "fetch", "-c", cfgpath,
		             "-o", (j.via !== "" ? j.via : "direct"), j.url ];
		let quoted = [];
		for (let a in argv) push(quoted, helpers.sq(a));
		let line = join(" ", quoted) + " > " + helpers.sq(j.outpath) + " 2>/dev/null";
		let to = (j.opts && j.opts.timeout) ? j.opts.timeout : 15;
		if (has_timeout) line = sprintf("timeout %d ", to) + line;
		try { system(["/bin/sh", "-c", line]); } catch (_) {}
		fs.unlink(cfgpath);
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
		if (match(t, /^(vmess|vless|ss|trojan|hy2|hysteria2|http|https):\/\//))
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

// build_fetch_config(cur, via) -> JSON string for `sing-box tools fetch -c`.
// Minimal config: the selected via-outbound (tag forced to `via`) + a direct
// outbound. via="" / "direct" -> just direct. Returns null if via is set but
// its section can't be built (caller logs + skips). No I/O.
function build_fetch_config(cur, via) {
	let direct = { tag: "direct", type: "direct" };
	let outbounds = [];
	if (via !== "" && via !== "direct") {
		let kind = helpers.uci_get_or_empty(cur, via, "type");
		if (kind === "") return null;
		let sec = cur.get_all("singbox-ui", via);
		if (sec == null) return null;
		let obj;
		try { obj = ob_mod.build_constructor_for(sec, kind); }
		catch (e) { return null; }
		if (obj == null) return null;
		obj.tag = via;
		push(outbounds, obj);
	}
	push(outbounds, direct);
	return sprintf("%J", { outbounds: outbounds });
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

	// Step 1: build one job per subscription. Each job carries the ephemeral
	// fetch-config JSON (outbounds: [via-outbound, direct]) so sing-box can
	// route the download through the selected outbound.
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
		let via = helpers.uci_get_or_empty(cur, name, "sub_update_via");
		let cfg_json = build_fetch_config(cur, via);
		if (cfg_json == null) {
			log_err(`fetch_subs: ${name} via outbound '${via}' could not be built, skipping`);
			continue;
		}
		let raw_path = `${TMPDIR}/sub_${name}.raw`;
		let out_path = `${TMPDIR}/sub_${name}.txt`;
		push(jobs, {
			name: name, raw_path: raw_path, out_path: out_path,
			url: url, via: via, cfg_json: cfg_json, outpath: raw_path,
			opts: { timeout: timeout },
		});
	}

	// Step 2: fetch each subscription via sing-box tools fetch.
	_fetcher(jobs);

	// Step 3: parse each result; on failure, leave existing out_path alone.
	for (let m in jobs) {
		let st = fs.stat(m.raw_path);
		if (!st || st.size === 0) {
			log_err(`fetch_subs: download failed for ${m.name}`);
			fs.unlink(m.raw_path);
			continue;
		}
		if (st.size > MAX_BODY) {
			log_err(`fetch_subs: ${m.name} body ${st.size} bytes exceeds ${MAX_BODY}, rejecting`);
			fs.unlink(m.raw_path);
			continue;
		}

		let raw = _reader(m.raw_path) ?? "";
		fs.unlink(m.raw_path);
		if (length(raw) === 0) {
			log_err(`fetch_subs: empty body for ${m.name}`);
			continue;
		}

		// try_b64_decode returns either the decoded blob (scheme-bearing
		// base64) or the original plaintext. Feed it straight into the line
		// scan so we don't hold a separate `decoded` copy alongside `raw`.
		let urls = [];
		for (let line in split(try_b64_decode(raw), "\n")) {
			let t = trim(line);
			if (t !== "" && match(lc(t), /^[a-z][a-z0-9+.-]*:\/\//))
				push(urls, t);
		}
		if (!length(urls)) {
			log_err(`fetch_subs: no valid proxy URL in response for ${m.name}`);
			continue;
		}

		if (!write_atomic(m.out_path, join("\n", urls) + "\n")) {
			log_err(`fetch_subs: cannot write ${m.out_path}`);
			continue;
		}
		log(`fetch_subs: ${m.name} -> ${m.out_path} (${length(urls)} urls)`);
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
		push(out, { name: name, enabled: enabled,
		            last_update: last_update, node_count: node_count });
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
	_set_io_for_test,
	_set_fetcher_for_test,
	_read_raw_for_test,
	_build_fetch_config_for_test: build_fetch_config,
	_cmd_fetch_subs_for_test: function(cur) { return cmd_fetch_subs(cur); },
	_cmd_sub_status_for_test: function(cur) { return cmd_sub_status(cur); },
	_any_subs_stale_for_test: function(cur, force, only) { return any_subs_stale(cur, force, only); },
	_subs_refresh_allowed_for_test: function(cur, force) { return subs_refresh_allowed(cur, force); },
};
