#!/usr/bin/ucode
// Unified subscription/ruleset fetcher and refresh driver.
// Subcommands:
//   fetch-subs                              — download all subscription outbounds
//   fetch-rulesets                          — download all nft_rules=1 rule-sets
//   refresh [subscriptions|rulesets|all] [force]
//
// Env overrides (used by tests):
//   SINGBOX_TMPDIR (default /tmp/singbox-ui)
//   SINGBOX        (default /usr/bin/sing-box)
//   UCI_CONFIG_DIR (honoured by require("uci").cursor)
//   SINGBOX_NO_RELOAD=1 — refresh skips the init.d reload (tests)

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
const SINGBOX    = getenv("SINGBOX")        || "/usr/bin/sing-box";
const DEFAULT_UA = "Mozilla/5.0";
// Cap subscription/ruleset bodies so a hostile or runaway source cannot OOM
// a 128–256 MB router. curl aborts past --max-filesize; the post-stat guard
// catches bodies with no Content-Length (chunked) and local cp sources.
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");

// Two channels: log() is ops-info, log_err() is errors. They both write to
// stderr (init.d/cron route it to syslog) but log_err tags severity so an
// operator reading logread can tell the two apart — they used to be byte
// identical, an illusion of separate channels.
function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn("error: " + msg + "\n"); }

// I/O seams — overridable for tests, mirroring log._set_logger_for_test.
// _reader(path) returns the raw body string (or null); _downloader(specs)
// runs the parallel curl transaction. BOTH `let` bindings are declared here,
// BEFORE the setter helpers below close over and assign to them — a forward
// reference would hit the temporal dead zone and throw at call time.
let _reader = function(path) {
	let fd = fs.open(path, "r");
	if (!fd) return null;
	let body;
	try { body = fd.read("all"); } catch (e) { body = null; }
	fd.close();
	return body;
};

// Default _downloader is the old parallel_download body, unchanged (it keeps
// the --max-filesize token from S3-2). Kicks off multiple curls under
// /bin/sh and waits for all in one transaction. Each spec: {url, outpath,
// opts}. Failures surface via the caller's fs.stat().
let _downloader = function(specs) {
	if (!length(specs)) return;
	let parts = [];
	for (let spec in specs) {
		let opts = spec.opts || {};
		let argv = [
			"curl", "-sfL",
			"--max-filesize", `${MAX_BODY}`,
			"--max-time", `${opts.timeout ?? 15}`,
			"-A", opts.user_agent || DEFAULT_UA,
			"-o", spec.outpath,
		];
		if (opts.interface) push(argv, "--interface", opts.interface);
		push(argv, spec.url);
		let quoted = [];
		for (let a in argv) push(quoted, helpers.sq(a));
		push(parts, join(" ", quoted) + " &");
	}
	push(parts, "wait");
	system(["/bin/sh", "-c", join(" ", parts)]);
};

// _set_io_for_test(downloader, reader) — install mock I/O. Either arg may be
// null to keep the current implementation. Declared AFTER _downloader/_reader
// so both targets are already in scope when this assigns to them.
function _set_io_for_test(downloader, reader) {
	if (downloader != null) _downloader = downloader;
	if (reader != null)     _reader = reader;
}

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

// Local rule-set sources must live under a known prefix to keep a hostile
// (or accidental) UCI value from copying /etc/shadow or similar into the
// work dir for `sing-box rule-set decompile` to swallow. Today only the
// LuCI admin can write UCI, but this is defense in depth.
function path_under_whitelist(p) {
	if (p == null || !length(p)) return false;
	let prefixes = ["/etc/", "/tmp/", "/var/", "/usr/share/"];
	for (let pref in prefixes) {
		if (substr(p, 0, length(pref)) === pref) return true;
	}
	return false;
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

function cmd_fetch_subs(cur) {
	let names = helpers.sections_of_kind(cur, "outbound", "type", "subscription");
	if (!length(names)) {
		log_err("fetch_subs: no subscription outbounds configured");
		return 0;
	}

	let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
	let timeout = boot ? 5 : 15;

	// Phase 1: build one job per subscription (download spec + metadata in a
	// single struct — no more index-parallel specs/meta arrays to desync).
	let jobs = [];
	for (let name in names) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_subs: ${name} disabled, skipping`);
			continue;
		}
		let url = helpers.uci_get_or_empty(cur, name, "sub_url");
		if (url === "") {
			log_err(`fetch_subs: ${name} has no sub_url, skipping`);
			continue;
		}
		let via = helpers.uci_get_or_empty(cur, name, "sub_update_via");
		let iface = null;
		if (via !== "" && via !== "direct") {
			let logical = helpers.uci_get_or_empty(cur, via, "interface");
			if (logical === "") {
				log_err(`fetch_subs: outbound '${via}' has no interface`);
				continue;
			}
			// `curl --interface` needs a real netdev (e.g. pppoe-wan); the
			// outbound stores a UCI logical name (e.g. wan). Translate so
			// the request leaves through the requested uplink.
			iface = helpers.resolve_iface_device(logical);
		}
		let raw_path = `${TMPDIR}/sub_${name}.raw`;
		let out_path = `${TMPDIR}/sub_${name}.txt`;
		push(jobs, {
			name: name, raw_path: raw_path, out_path: out_path,
			url: url, outpath: raw_path,
			opts: { timeout: timeout, interface: iface },
		});
	}

	// Phase 2: parallel curl (each job is also a valid download spec).
	_downloader(jobs);

	// Phase 3: parse each result; on failure, leave existing out_path alone.
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

		let decoded = try_b64_decode(raw);
		let urls = [];
		for (let line in split(decoded, "\n")) {
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
function cmd_fetch_rulesets(cur) {
	// Only matches `ruleset` sections — earlier this iterated all sections
	// with nft_rules='1' and picked up tproxy inbounds, causing
	// any_rulesets_stale() to fire on cron forever (the inbound rs_*.json
	// never exists) and to needlessly reload sing-box every 30 minutes.
	let names = helpers.sections_of_kind(cur, "ruleset", "nft_rules", "1");
	if (!length(names)) {
		log_err("fetch_rulesets: no rule-sets configured (nft_rules=1)");
		return 0;
	}

	let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
	let timeout = boot ? 10 : 30;

	let jobs = [];   // each: { name, raw_path, out_path, rs_type, target,
	                 //         download? (remote only): url, outpath, opts }
	for (let name in names) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_rulesets: ${name} disabled, skipping`);
			continue;
		}
		let rs_type = helpers.uci_get_or_empty(cur, name, "type");
		let raw_path = `${TMPDIR}/rs_${name}.raw`;
		let out_path = `${TMPDIR}/rs_${name}.json`;
		let target = (rs_type === "remote") ? helpers.uci_get_or_empty(cur, name, "url")
		             : (rs_type === "local")  ? helpers.uci_get_or_empty(cur, name, "path")
		             : "";
		if (target === "") {
			log_err(`fetch_rulesets: ${name} has no source, skipping`);
			continue;
		}

		if (rs_type === "remote") {
			push(jobs, {
				name: name, raw_path: raw_path, out_path: out_path,
				rs_type: rs_type, target: target,
				url: target, outpath: raw_path, opts: { timeout: timeout },
			});
		} else if (rs_type === "local") {
			// Restrict local copies to a small set of known prefixes
			// (/etc, /tmp, /var, /usr/share) — defense in depth so a
			// hostile UCI value cannot pull /etc/shadow or similar.
			if (!path_under_whitelist(target)) {
				log_err(`fetch_rulesets: ${name} target path '${target}' outside whitelist (/etc, /tmp, /var, /usr/share), rejecting`);
				continue;
			}
			// cp follows symlinks: a whitelisted path may itself be a symlink
			// pointing OUTSIDE the whitelist (e.g. /tmp/x -> /proc/version).
			// Detect the link with fs.lstat and resolve its destination with
			// fs.readlink — the lstat struct does NOT expose the link target
			// (no `.target` field); readlink is the ucode fs API for it. The
			// call is try-wrapped so a build lacking readlink degrades to
			// "reject the symlink" (dest stays null) rather than throwing. We
			// re-check the prefix guard against the resolved destination; a
			// relative or out-of-whitelist target is rejected (a relative
			// ruleset symlink is never legitimate, and realpath may be absent).
			let lst = fs.lstat(target);
			if (lst && lst.type === "link") {
				let dest = null;
				try { dest = fs.readlink(target); } catch (_) {}
				if (dest == null || substr(dest, 0, 1) !== "/") {
					log_err(`fetch_rulesets: ${name} symlink '${target}' has unresolvable/relative target '${dest}', rejecting`);
					continue;
				}
				if (!path_under_whitelist(dest)) {
					log_err(`fetch_rulesets: ${name} symlink '${target}' resolved to '${dest}' outside whitelist, rejecting`);
					continue;
				}
			}
			// Local copies are cheap, do them inline.
			if (system(["cp", "--", target, raw_path]) !== 0) {
				log_err(`fetch_rulesets: cannot read: ${target}`);
				// cp may have left a partial file behind; remove it so
				// stale content never reaches sing-box rule-set decompile.
				fs.unlink(raw_path);
				continue;
			}
			push(jobs, { name: name, raw_path: raw_path, out_path: out_path, rs_type: rs_type, target: target });
		} else {
			log_err(`fetch_rulesets: unknown type '${rs_type}' for ${name}`);
			continue;
		}
	}

	// Only remote jobs carry a download spec (url/outpath/opts); local jobs
	// were already cp'd inline above. The downloader ignores entries with no
	// `url`, so passing the whole list is safe.
	_downloader(filter(jobs, function(j) { return j.url != null; }));

	// Decompile / promote each raw file.
	for (let m in jobs) {
		let st = fs.stat(m.raw_path);
		if (!st || st.size === 0) {
			log_err(`fetch_rulesets: download failed for ${m.name} (${m.target})`);
			fs.unlink(m.raw_path);
			continue;
		}
		if (st.size > MAX_BODY) {
			log_err(`fetch_rulesets: ${m.name} body ${st.size} bytes exceeds ${MAX_BODY}, rejecting`);
			fs.unlink(m.raw_path);
			continue;
		}
		let fmt = helpers.detect_rs_format(m.target, helpers.uci_get_or_empty(cur, m.name, "format"));
		if (fmt === "binary") {
			if (system([SINGBOX, "rule-set", "decompile", m.raw_path, "-o", m.out_path]) !== 0) {
				log_err(`fetch_rulesets: decompile failed for ${m.name}`);
				fs.unlink(m.raw_path);
				continue;
			}
		} else {
			if (system(["cp", "--", m.raw_path, m.out_path]) !== 0) {
				log_err(`fetch_rulesets: cannot copy source for ${m.name}`);
				fs.unlink(m.raw_path);
				continue;
			}
		}
		fs.unlink(m.raw_path);
		log(`fetch_rulesets: ${m.name} -> ${m.out_path}`);
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

function any_subs_stale(cur, force) {
	for (let name in helpers.sections_of_kind(cur, "outbound", "type", "subscription")) {
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

function any_rulesets_stale(cur, force) {
	for (let name in helpers.sections_of_kind(cur, "ruleset", "nft_rules", "1")) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") continue;
		let iv = +helpers.uci_get_or_empty(cur, name, "update_interval");
		// !(iv > 0) catches NaN/0/negatives — see any_subs_stale for the bug.
		if (!(iv > 0)) iv = 86400;
		if (is_stale(`${TMPDIR}/rs_${name}.json`, iv, force)) return true;
	}
	return false;
}

function cmd_refresh(cur, what, force) {
	let refreshed = false;
	if (what === "subscriptions" || what === "all") {
		if (any_subs_stale(cur, force)) {
			cmd_fetch_subs(cur);
			refreshed = true;
		}
	}
	if (what === "rulesets" || what === "all") {
		if (any_rulesets_stale(cur, force)) {
			cmd_fetch_rulesets(cur);
			refreshed = true;
		}
	}
	if (refreshed && getenv("SINGBOX_NO_RELOAD") !== "1") {
		system(["/etc/init.d/singbox-ui", "reload"]);
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
	case "fetch-subs":     cmd_fetch_subs(cur); break;
	case "fetch-rulesets": cmd_fetch_rulesets(cur); break;
	case "refresh":        cmd_refresh(cur, argv[1] || "all", argv[2] === "force"); break;
	default:
		log_err("usage: subscription.uc {fetch-subs|fetch-rulesets|refresh [what] [force]}");
		exit(2);
	}
}

return {
	try_b64_decode,
	path_under_whitelist,
	is_stale,
	_set_io_for_test,
	_read_raw_for_test,
};
