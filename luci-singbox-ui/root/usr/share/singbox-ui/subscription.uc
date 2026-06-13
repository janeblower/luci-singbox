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
// Cap subscription/ruleset bodies so a hostile or runaway source cannot OOM
// a 128–256 MB router. The post-stat guard (Phase 3) enforces MAX_BODY for
// subscription bodies; local cp sources are also covered.
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB

// nft_rules remote rule-sets are no longer curl'd; we read the already-compiled
// .srs straight from sing-box's bbolt cache (cache.db / bucket rule_set / key =
// section name) via bbolt-client. These seams are test-overridable.
const BBOLT_BIN     = getenv("SINGBOX_BBOLT_BIN") || "/usr/libexec/singbox-ui/bbolt-client";
const RS_CACHE_WAIT = +(getenv("SINGBOX_RS_CACHE_WAIT") || "10");   // sec, cold-cache poll
// Trigger/apply seams. init.d reload is stop+start (sing-box has no signal
// reload) — used to make sing-box fetch+cache a cold remote rule-set. The nft
// apply re-runs nftables.uc so rebuilt rs_*.json reach the live ruleset.
const SINGBOX_INITD = getenv("SINGBOX_INITD")     || "/etc/init.d/singbox-ui";
const NFT_APPLY_CMD = getenv("SINGBOX_NFT_APPLY")
	|| "ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/nftables.uc apply";

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");
let cache_mod = require("cache");
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

// bbolt_available() — path to the executable bbolt-client, or null. Defined
// before its callers (cmd_fetch_rulesets, cmd_refresh) per ucode's
// callee-precedes-caller rule (no function hoisting).
function bbolt_available() {
	let st = fs.stat(BBOLT_BIN);
	return (st && st.type === "file") ? BBOLT_BIN : null;
}

// cache_extract_srs(db, tag, out_path) — write the .srs payload of `tag` from
// cache.db (bucket rule_set) into out_path. Returns true on success (rc 0 and
// non-empty file). Runs through /bin/sh with stdout redirection; every argument
// is single-quoted via helpers.sq so a hostile tag/path cannot break out.
//
// The `>` redirect (S4-6) targets a sibling tmp path, not out_path directly, so
// a bbolt failure or empty body never leaves a 0-byte rs_*.raw observable at the
// real path; we fs.rename onto out_path only after rc==0 AND size>0. A failed
// extract cleans up the tmp file and leaves any prior out_path untouched.
function cache_extract_srs(db, tag, out_path) {
	let bin = bbolt_available();
	if (!bin) return false;
	let tmp = sprintf("%s.tmp.%d", out_path, time());
	let cmd = helpers.sq(bin) + " -r " + helpers.sq(db) + " rule_set " +
	          helpers.sq(tag) + " > " + helpers.sq(tmp) + " 2>/dev/null";
	if (system(["/bin/sh", "-c", cmd]) !== 0) { fs.unlink(tmp); return false; }
	let st = fs.stat(tmp);
	if (!st || st.size === 0) { fs.unlink(tmp); return false; }
	let renamed = false;
	try { renamed = fs.rename(tmp, out_path); } catch (_) { renamed = false; }
	if (!renamed) { fs.unlink(tmp); return false; }
	return true;
}

// cache_list_keys(db) — one bbolt-client list call returning a {tag:true} set of
// the keys present in the rule_set bucket of cache.db, or null on probe failure.
// Batching the list once per poll (S4-5) avoids forking bbolt-client per-tag.
function cache_list_keys(db) {
	let bin = bbolt_available();
	if (!bin) return null;
	let cmd = helpers.sq(bin) + " " + helpers.sq(db) + " rule_set 2>/dev/null";
	let p = fs.popen(cmd, "r");
	if (!p) return null;
	let raw = p.read("all") ?? "";
	p.close();
	let keys = {};
	for (let line in split(raw, "\n")) {
		let t = trim(line);
		if (t !== "") keys[t] = true;
	}
	return keys;
}

// --- Cold-reload backoff (S4-1) ------------------------------------------
// A remote nft rule-set whose URL is dead/404/typo'd never compiles into
// cache.db, so its tag is forever cold. Without a backoff, cmd_refresh issued a
// full stop+start `init.d reload` every 30-min cron cycle, dropping every live
// proxy connection, then still failed. We persist the last cold-reload attempt
// time per tag in a sentinel file and refuse to reload again for that tag until
// its own update_interval has elapsed since the failure. Warm tags never reach
// this path (they are not cold), so their behaviour is unchanged.
//
// Defined here (before cmd_fetch_rulesets) because cmd_fetch_rulesets clears the
// sentinel on a successful extract and ucode has no function hoisting; the
// consumer retry_eligible_cold_tags lives later next to cmd_refresh.

// tag_update_interval(cur, tag) — the tag's configured refresh interval in
// seconds (default 86400, mirroring any_rulesets_stale's fallback). This is the
// minimum backoff before a still-cold tag may trigger another reload.
function tag_update_interval(cur, tag) {
	let iv = +helpers.uci_get_or_empty(cur, tag, "update_interval");
	if (!(iv > 0)) iv = 86400;
	return iv;
}

// cold_sentinel_path(tag) — per-tag sentinel under TMPDIR. The tag is a UCI
// section name ([a-zA-Z0-9_]), so it is safe as a path component.
function cold_sentinel_path(tag) {
	return `${TMPDIR}/.rs_cold_${tag}.attempt`;
}

// record_cold_attempt(tag) — write the sentinel (mtime = now) so the next cycle
// can measure elapsed time since this failed reload attempt.
function record_cold_attempt(tag) {
	let f = fs.open(cold_sentinel_path(tag), "w");
	if (!f) return;
	try { f.write(`${time()}\n`); } catch (_) {}
	f.close();
}

// clear_cold_attempt(tag) — drop the sentinel once the tag has been successfully
// extracted, so a tag that recovers immediately becomes eligible again.
function clear_cold_attempt(tag) {
	try { fs.unlink(cold_sentinel_path(tag)); } catch (_) {}
}

// cold_retry_eligible(cur, tag) — may this cold tag trigger a reload now? Yes if
// it has no sentinel (never attempted, or just recovered) or its update_interval
// has elapsed since the last recorded attempt. A future-dated/garbage sentinel
// (clock skew) is treated as eligible rather than wedging the tag forever.
function cold_retry_eligible(cur, tag) {
	let st = fs.stat(cold_sentinel_path(tag));
	if (!st) return true;
	// A future-dated sentinel (clock skew: RTC-less router corrected by NTP
	// after the stamp was written) would make time()-mtime negative and wedge
	// the tag until wall-clock crawled past mtime+interval. Treat it as elapsed.
	if (st.mtime > time()) return true;
	return (time() - st.mtime) >= tag_update_interval(cur, tag);
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

	// Phase 1: build one job per subscription. Each job carries the ephemeral
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

	// Phase 2: fetch each subscription via sing-box tools fetch.
	_fetcher(jobs);

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
			// nft_rules remote: pull the already-compiled .srs from sing-box's
			// bbolt cache (cache.db / bucket rule_set / key = section name)
			// instead of curl'ing the URL a second time — sing-box already
			// downloaded and cached the same rule-set. All cold edges degrade
			// to skip+log (the cold-cache trigger lives in cmd_refresh).
			let db = cache_mod.cache_db_path(cur);
			if (db == null) {
				log_err(`fetch_rulesets: ${name} skipped — cache_file disabled (enable [cache] to build nft rules)`);
				continue;
			}
			if (!bbolt_available()) {
				log_err(`fetch_rulesets: ${name} skipped — bbolt-client not installed (reinstall or upgrade the package)`);
				continue;
			}
			if (!cache_extract_srs(db, name, raw_path)) {
				log_err(`fetch_rulesets: ${name} not in cache.db yet (will appear after sing-box fetches it), skipping`);
				continue;
			}
			// The tag is now warm in cache.db — drop any cold-reload backoff
			// sentinel so a recovered rule-set is immediately retry-eligible
			// (S4-1). A still-dead tag never reaches here, so its sentinel
			// persists and keeps the reload backed off.
			clear_cold_attempt(name);
			// The cache always stores a compiled .srs → force binary decompile.
			push(jobs, { name: name, raw_path: raw_path, out_path: out_path,
			             rs_type: rs_type, target: target, force_binary: true });
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

	// No network download here: remote rule-sets were extracted from
	// cache.db (.srs → raw_path) and local ones cp'd inline above. Subscriptions
	// use _fetcher (sing-box tools fetch); rule-sets do not — they read from cache.

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
		// Cache-extracted remote rule-sets are always compiled .srs (force
		// binary); local sources keep extension-based detection.
		let fmt = m.force_binary ? "binary"
		          : helpers.detect_rs_format(m.target, helpers.uci_get_or_empty(cur, m.name, "format"));
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

// remote_nft_tags(cur) — names of enabled remote rule-sets with nft_rules=1.
// These are the cache.db keys we expect sing-box to have compiled.
function remote_nft_tags(cur) {
	let out = [];
	for (let name in helpers.sections_of_kind(cur, "ruleset", "nft_rules", "1")) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") continue;
		if (helpers.uci_get_or_empty(cur, name, "type") !== "remote") continue;
		push(out, name);
	}
	return out;
}

// any_tag_cold(db, tags) — true if at least one tag is missing from cache.db.
// Single batched list call (cache_list_keys) instead of one fork per tag.
function any_tag_cold(db, tags) {
	let keys = cache_list_keys(db);
	if (keys == null) return true;     // probe failed → treat as cold
	for (let t in tags) if (keys[t] !== true) return true;
	return false;
}

// wait_for_tags(db, tags, deadline_s) — poll cache.db (1s) until every tag is
// present or the deadline passes. Returns true if all appeared. Used after a
// cold-cache reload so the just-restarted sing-box has time to fetch+cache the
// remote rule-sets before we extract them.
//
// Pacing (S4-5): each iteration sleeps 1s via the external `sleep`. If `sleep`
// is missing/unforkable, system() returns non-zero and would return instantly —
// without a guard the loop would busy-spin (forking bbolt-client) until the
// deadline. So we also bound the iteration count to deadline_s+1 and bail when
// it's exhausted, guaranteeing termination even if `sleep` never paces us.
function wait_for_tags(db, tags, deadline_s) {
	let end = time() + deadline_s;
	let iters = 0;
	let max_iters = deadline_s + 1;
	while (true) {
		if (!any_tag_cold(db, tags)) return true;
		if (time() >= end) return false;
		if (++iters > max_iters) return false;
		if (system(["sleep", "1"]) !== 0) return false;
	}
}

// retry_eligible_cold_tags(cur, db, tags, force) — the subset of `tags` that are
// both cold AND outside their backoff window. An empty result means every cold
// tag is still backing off, so cmd_refresh must NOT reload. An explicit
// force-refresh (operator clicked Refresh in the UI, e.g. after fixing a typo'd
// URL) treats every cold tag as eligible regardless of its backoff window —
// otherwise a recovered URL could stay suppressed for up to a full
// update_interval. The cron path (force=false) keeps the throttling intact.
// (Backoff helpers cold_sentinel_path/cold_retry_eligible/record_cold_attempt/
// clear_cold_attempt live up near cmd_fetch_rulesets, which also clears the
// sentinel on success — ucode has no function hoisting, so a callee must precede
// its caller.)
function retry_eligible_cold_tags(cur, db, tags, force) {
	let keys = cache_list_keys(db);
	let out = [];
	for (let t in tags) {
		let cold = (keys == null) || (keys[t] !== true);
		if (cold && (force || cold_retry_eligible(cur, t))) push(out, t);
	}
	return out;
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

function cmd_refresh(cur, what, force, name) {
	let subs_refreshed = false;
	let no_reload = getenv("SINGBOX_NO_RELOAD") === "1";

	if (what === "subscriptions" || what === "all") {
		if (any_subs_stale(cur, force, name)) {
			cmd_fetch_subs(cur, name);
			subs_refreshed = true;
		}
	}

	if (what === "rulesets" || what === "all") {
		if (any_rulesets_stale(cur, force)) {
			// Cold cache: if a remote nft rule-set isn't compiled into cache.db
			// yet, issue ONE init.d reload (stop+start — sing-box fetches+caches
			// remote rule-sets on start) and poll cache.db for the keys. Skipped
			// in boot mode (sing-box not up yet) and when reload is suppressed
			// (tests). Warm tags skip the reload entirely so live connections
			// survive a routine refresh.
			//
			// S4-1: a dead/404 remote rule-set is forever cold, so an unguarded
			// any_tag_cold() reloaded (= stop+start, all connections dropped)
			// every cron cycle and still failed. We only reload when at least one
			// cold tag is *retry-eligible* — i.e. has never been tried or has been
			// backing off for its own update_interval since the last failed
			// attempt — and we stamp the sentinel for every tag still cold after
			// wait_for_tags so the dead one backs off until its next interval.
			let db = cache_mod.cache_db_path(cur);
			let tags = remote_nft_tags(cur);
			let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
			if (db != null && length(tags) && !boot && !no_reload) {
				let eligible = retry_eligible_cold_tags(cur, db, tags, force);
				if (length(eligible)) {
					log("refresh: cold rule-set in cache.db; reloading sing-box to populate it");
					system([SINGBOX_INITD, "reload"]);
					wait_for_tags(db, tags, RS_CACHE_WAIT);
					// Stamp the backoff for tags that are STILL cold after the
					// reload+poll (dead URLs); clear it for any that warmed up so
					// a recovered tag is immediately eligible again.
					let after = cache_list_keys(db);
					for (let t in tags) {
						if (after != null && after[t] === true) clear_cold_attempt(t);
						else record_cold_attempt(t);
					}
				}
			}
			cmd_fetch_rulesets(cur);
			// Re-apply nft so rebuilt rs_*.json reach the live ruleset (a routine
			// warm refresh does not reload, so nft would otherwise stay stale).
			if (!no_reload) system(["/bin/sh", "-c", NFT_APPLY_CMD]);
		}
	}

	// Subscriptions still need a sing-box reload to pick up new sub config.
	// Rule-sets handled their own reload/apply above, so no extra stop+start.
	if (subs_refreshed && !no_reload) {
		system([SINGBOX_INITD, "reload"]);
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
	case "refresh":        cmd_refresh(cur, argv[1] || "all", argv[2] === "force", argv[3]); break;
	case "sub-status":     printf("%J\n", cmd_sub_status(cur)); break;
	default:
		log_err("usage: subscription.uc {fetch-subs|fetch-rulesets|refresh [what] [force]|sub-status}");
		exit(2);
	}
}

return {
	try_b64_decode,
	path_under_whitelist,
	is_stale,
	_set_io_for_test,
	_set_fetcher_for_test,
	_read_raw_for_test,
	_build_fetch_config_for_test: build_fetch_config,
	_cmd_fetch_subs_for_test: function(cur) { return cmd_fetch_subs(cur); },
	_cmd_sub_status_for_test: function(cur) { return cmd_sub_status(cur); },
	_any_subs_stale_for_test: function(cur, force, only) { return any_subs_stale(cur, force, only); },
};
