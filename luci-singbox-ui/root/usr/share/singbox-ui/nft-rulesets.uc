#!/usr/bin/ucode
// nft rule-set fetcher/refresh driver. Rule-sets are updated by sing-box
// itself; we only extract the already-compiled .srs from sing-box's bbolt
// cache (cache.db / bucket rule_set / key = section name), decompile it to
// rs_<name>.json and re-apply nft. Split out of subscription.uc — subscriptions
// and rule-sets have entirely different update mechanisms.
// Subcommands:
//   fetch                 — extract+decompile all nft_rules=1 rule-sets
//   refresh [force]       — stale-check; cold-cache reload+poll; fetch; nft apply
//
// Env overrides (tests): SINGBOX_TMPDIR, SINGBOX, UCI_CONFIG_DIR,
//   SINGBOX_BBOLT_BIN, SINGBOX_RS_CACHE_WAIT, SINGBOX_INITD, SINGBOX_NFT_APPLY,
//   SINGBOX_BOOT_FETCH, SINGBOX_NO_RELOAD.

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
const SINGBOX    = getenv("SINGBOX")        || "/usr/bin/sing-box";
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB
const BBOLT_BIN     = getenv("SINGBOX_BBOLT_BIN") || "/usr/libexec/singbox-ui/bbolt-client";
const RS_CACHE_WAIT = +(getenv("SINGBOX_RS_CACHE_WAIT") || "10");
const SINGBOX_INITD = getenv("SINGBOX_INITD")     || "/etc/init.d/singbox-ui";
const NFT_APPLY_CMD = getenv("SINGBOX_NFT_APPLY")
	|| "ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/nftables.uc apply";

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");
let cache_mod = require("cache");

function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn("error: " + msg + "\n"); }

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

function cmd_refresh(cur, force) {
	let no_reload = getenv("SINGBOX_NO_RELOAD") === "1";
	if (!any_rulesets_stale(cur, force)) return 0;

	// Cold cache: a remote nft rule-set not yet compiled into cache.db triggers
	// ONE init.d reload (stop+start — sing-box fetches+caches on start), then we
	// poll cache.db. S4-1 backoff: only reload when a cold tag is retry-eligible.
	let db = cache_mod.cache_db_path(cur);
	let tags = remote_nft_tags(cur);
	let boot = getenv("SINGBOX_BOOT_FETCH") === "1";
	if (db != null && length(tags) && !boot && !no_reload) {
		let eligible = retry_eligible_cold_tags(cur, db, tags, force);
		if (length(eligible)) {
			log("refresh: cold rule-set in cache.db; reloading sing-box to populate it");
			system([SINGBOX_INITD, "reload"]);
			wait_for_tags(db, tags, RS_CACHE_WAIT);
			let after = cache_list_keys(db);
			for (let t in tags) {
				if (after != null && after[t] === true) clear_cold_attempt(t);
				else record_cold_attempt(t);
			}
		}
	}
	cmd_fetch_rulesets(cur);
	if (!no_reload) system(["/bin/sh", "-c", NFT_APPLY_CMD]);
	return 0;
}

let uci_dir = getenv("UCI_CONFIG_DIR");
let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
fs.mkdir(TMPDIR, 0o755);

if (length(ARGV)) {
	let argv = ARGV;
	let sub = argv[0] || "";
	switch (sub) {
	case "fetch":   cmd_fetch_rulesets(cur); break;
	case "refresh": cmd_refresh(cur, argv[1] === "force"); break;
	default:
		log_err("usage: nft-rulesets.uc {fetch|refresh [force]}");
		exit(2);
	}
}

// NOTE: this file is invoked only by CLI path (init.d/cron/rpcd) and is NOT
// require()-able — ucode rejects the hyphen in the module name. These exports are
// therefore inert today; tests drive this module behaviorally via the CLI. Kept
// for parity with subscription.uc and in case the file is ever made importable.
return {
	path_under_whitelist,
	is_stale,
	_cmd_fetch_rulesets_for_test: function(cur) { return cmd_fetch_rulesets(cur); },
	_any_rulesets_stale_for_test: function(cur, force) { return any_rulesets_stale(cur, force); },
};
