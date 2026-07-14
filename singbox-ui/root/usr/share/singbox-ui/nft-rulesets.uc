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
//   SINGBOX_RS_CACHE_WAIT, SINGBOX_INITD, SINGBOX_NFT_APPLY,
//   SINGBOX_BOOT_FETCH, SINGBOX_NO_RELOAD.

const TMPDIR     = getenv("SINGBOX_TMPDIR") || "/tmp/singbox-ui";
const SINGBOX    = getenv("SINGBOX")        || "/usr/bin/sing-box";
const MAX_BODY   = 8 * 1024 * 1024;   // 8 MiB
const RS_CACHE_WAIT = +(getenv("SINGBOX_RS_CACHE_WAIT") || "10");
const SINGBOX_INITD = getenv("SINGBOX_INITD")     || "/etc/init.d/singbox-ui";
const NFT_APPLY_CMD = getenv("SINGBOX_NFT_APPLY")
	|| "ucode -L /usr/share/singbox-ui/lib /usr/share/singbox-ui/nftables.uc apply";

let fs  = require("fs");
let uci_mod = require("uci");
let helpers = require("helpers");
let cache_mod = require("cache");
let bb = require("bbolt");   // read-only bbolt reader — in-process, no fork

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

// resolve_local_source(target) — SEC-8: resolve a local rule-set source to a
// final REAL path that is provably (a) under the whitelist and (b) a regular
// file, defeating symlink escapes the prior single-hop guard missed:
//   - a multi-hop chain (/tmp/a -> /tmp/b -> /etc/shadow, each hop whitelisted
//     at readlink time but the chain landing outside), and
//   - a symlinked PARENT directory (/tmp/dir -> /, then /tmp/dir/etc/shadow):
//     the kernel follows the parent symlink, so a textual whitelist check on the
//     ORIGINAL path is fooled (it still starts with /tmp/) while the real file
//     lives outside.
//
// Strategy: prefer fs.realpath, which canonicalises EVERY path component (parent
// symlinks included) in one call, then whitelist-check the canonical path. If
// realpath is absent on this ucode build (it is on some stock images — see the
// historical note) or fails, fall back to a bounded readlink-chain walk that
// catches the multi-hop LEAF case (it cannot see a symlinked parent, so the
// textual whitelist check there is the best available without realpath —
// strictly no weaker than the prior single-hop guard). The final target must
// lstat as a regular "file" (not a dir/device/fifo/dangling link). Returns the
// validated real path, or null (caller rejects + logs).
const MAX_LINK_HOPS = 16;
function resolve_local_source(target) {
	if (!path_under_whitelist(target)) return null;

	// Preferred path: canonicalise the WHOLE path (parent symlinks included).
	if (type(fs.realpath) === "function") {
		let real = null;
		try { real = fs.realpath(target); } catch (_) {}
		// realpath null/empty = missing component / dangling link → reject.
		if (real == null || real === "") return null;
		if (!path_under_whitelist(real)) return null;
		let rst = fs.lstat(real);                    // canonical → never a link
		if (!rst || rst.type !== "file") return null;
		return real;
	}

	// Fallback (no realpath): bounded readlink-chain walk of the leaf.
	let cur_path = target;
	for (let hop = 0; hop <= MAX_LINK_HOPS; hop++) {
		let lst = fs.lstat(cur_path);
		if (!lst) return null;                       // missing component
		if (lst.type !== "link") {
			if (lst.type !== "file") return null;    // only a plain regular file
			return path_under_whitelist(cur_path) ? cur_path : null;
		}
		if (hop === MAX_LINK_HOPS) return null;      // chain too long / cycle
		let dest = null;
		try { dest = fs.readlink(cur_path); } catch (_) {}
		if (dest == null || dest === "") return null;
		// Resolve a relative link target against the link's own directory.
		if (substr(dest, 0, 1) !== "/") {
			let dir = fs.dirname(cur_path) ?? "/";
			dest = (dir === "/") ? `/${dest}` : `${dir}/${dest}`;
		}
		if (!path_under_whitelist(dest)) return null;
		cur_path = dest;
	}
	return null;
}

// Why the last probe failed, as the reader itself put it ("cannot open database"
// / "empty database" / "invalid database"). Absent, truncated and CORRUPT are very
// different operator problems — a corrupt cache.db never self-heals, so without
// this the operator reads one identical "absent or unreadable" line every cron
// cycle, forever, on a device that is awkward to debug. Set by the probe's catch
// blocks, consumed by the deferral log lines. Diagnostics only: it never steers a
// decision.
let last_probe_err = "";

// cache_open(db) — open cache.db and locate the `rule_set` bucket. Returns
// { m, ps, bp } or null. Defined before its callers per ucode's
// callee-precedes-caller rule (no function hoisting).
//
// A null return means the PROBE FAILED: the file is absent, truncated, or
// otherwise unreadable, so we learned NOTHING about the tags. It never means
// "the tags are cold" — SEC-10 depends on that distinction (see
// retry_eligible_cold_tags). Every failure mode of the reader lands here,
// because it throws rather than exiting (lib/bbolt.uc bad()).
//
// A readable db with NO rule_set bucket is emphatically NOT a failure: it is
// confirmed evidence that sing-box has cached no rule-sets at all (it creates
// the bucket lazily, on the first one it saves). So bp stays null, the key set
// comes back empty, and the tags read as genuinely cold. Folding that into the
// null probe would wedge the exact scenario the cold-reload exists for — one
// nft rule-set with a dead URL means no bucket, so an operator who fixes the URL
// and hits Refresh would be told "probe failed" and never get their reload.
function cache_open(db) {
	last_probe_err = "";
	try {
		let m = bb.read_db(db);
		if (m == null) return null;
		let ps = bb.page_size(m);
		let root = bb.select_root(m, ps);
		let bref = bb.find_bucket(m, ps, root, "rule_set");
		let bp = null;
		if (bref != null)
			bp = (bref.page != null) ? bb.page(m, ps, bref.page) : bref.inline;
		return { m: m, ps: ps, bp: bp };
	} catch (e) {
		last_probe_err = e.message ?? "unknown reader error";
		return null;
	}
}

// cache_extract_srs(c, tag, out_path) — write the .srs payload of `tag` from an
// ALREADY-OPEN cache handle into out_path. Returns true on success.
//
// The tmp+rename dance stays: it is genuine atomicity, so a failed or empty read
// never leaves a 0-byte rs_*.raw observable at the real path (S4-6). What it no
// longer has to do is launder the exit status of a forked shell.
function cache_extract_srs(c, tag, out_path) {
	if (c == null || c.bp == null) return false;
	let payload = null;
	// A page deeper in the tree can still be corrupt even though cache_open
	// succeeded; the reader throws, and one bad tag must not abort the run.
	// unwrap_ruleset is INSIDE the same try on purpose: it reads the envelope with
	// raw substr/ord today and so cannot throw, but the moment anyone hardens it
	// onto the bounds-checked sub()/bad() path — which is exactly what the rest of
	// the reader uses — a corrupt envelope would become an uncaught die() that
	// aborts the whole refresh mid-loop: no nft apply, no log, for every remaining
	// rule-set. The guard costs nothing; discovering its absence would cost a router.
	try {
		let r = bb.search(c.m, c.ps, c.bp, tag, 0);
		// plain key only; a sub-bucket entry (flags&1) carries no value
		if (r == null || (r[0] & 0x01) != 0) return false;
		payload = bb.unwrap_ruleset(r[1]);
	} catch (_) { return false; }
	if (payload == null || length(payload) === 0) return false;

	let tmp = sprintf("%s.tmp.%d", out_path, time());
	let fh = null;
	try { fh = fs.open(tmp, "w"); } catch (_) { return false; }
	if (!fh) return false;
	let wrote = fh.write(payload);
	// flush() before close(): write() can report the full length when the payload
	// still sits in the stdio buffer, and close() returns true even when its flush
	// failed (ucode's fs.file signals write errors by RETURNING null, never by
	// throwing). Without this, a small ENOSPC'd .srs passes the length check below.
	let flushed = false;
	try { flushed = (fh.flush() != null); } catch (_) { flushed = false; }
	fh.close();
	// Short write, not just a zero/null one: ENOSPC on a full router flash writes
	// a PREFIX of the payload and reports it honestly. Reject a truncated .srs here
	// rather than shipping it to `rule-set decompile` and hoping that notices.
	if (!flushed || wrote !== length(payload)) { helpers.unlink_quiet(tmp); return false; }
	let st = fs.stat(tmp);
	if (!st || st.size === 0) { helpers.unlink_quiet(tmp); return false; }
	let renamed = false;
	try { renamed = fs.rename(tmp, out_path); } catch (_) { renamed = false; }
	if (!renamed) { helpers.unlink_quiet(tmp); return false; }
	return true;
}

// cache_list_keys(db) — the {tag:true} set of keys in the rule_set bucket, or
// null on probe failure (SEC-10). An empty set is a real answer: the db is
// readable and holds no rule-sets.
//
// Deliberately re-opens the db on EVERY call: wait_for_tags polls this in a 1s
// loop while sing-box is still writing newly-fetched rule-sets into cache.db, so
// a hoisted handle would poll a stale snapshot forever and the wait could never
// succeed. (cmd_fetch_rulesets, by contrast, opens ONCE and extracts every tag
// from that one handle — bbolt is copy-on-write, so that is a consistent
// snapshot, which is strictly better than the N independent whole-file reads the
// forked binary used to do.)
function cache_list_keys(db) {
	let c = cache_open(db);
	if (c == null) return null;
	if (c.bp == null) return {};        // readable, but nothing cached yet
	let acc = [];
	try { bb.walk(c.m, c.ps, c.bp, false, 0, acc); }
	catch (e) { last_probe_err = e.message ?? "unknown reader error"; return null; }
	let keys = {};
	for (let k in acc) {
		let t = trim(k);
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

	// One open per run: bbolt is copy-on-write, so every tag below is extracted
	// from a single consistent snapshot instead of re-reading the whole file once
	// per tag (which is what forking the CLI shim per tag used to cost).
	let cache_db = cache_mod.cache_db_path(cur);
	let cache_handle = (cache_db != null) ? cache_open(cache_db) : null;

	let jobs = [];   // each: { name, raw_path, out_path, rs_type, target,
	                 //         download? (remote only): url, outpath, opts }
	for (let name in names) {
		// Same predicate the config path uses (route.uc / dns.uc): a builtin
		// rule-set that the master switch turned off must not be fetched either,
		// or cron keeps pulling .srs files nothing references.
		let sec = cur.get_all("singbox-ui", name);
		if (sec == null || !helpers.ruleset_active(cur, sec)) {
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
			if (cache_db == null) {
				log_err(`fetch_rulesets: ${name} skipped — cache_file disabled (enable [cache] to build nft rules)`);
				continue;
			}
			// cache_handle == null is a failed PROBE, not a cold tag: the file is
			// missing or unreadable (see cache_open).
			if (cache_handle == null) {
				log_err(`fetch_rulesets: ${name} skipped — cache.db unreadable: ${last_probe_err || "absent"} (sing-box not started yet, or [cache] just enabled)`);
				continue;
			}
			if (!cache_extract_srs(cache_handle, name, raw_path)) {
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
			// SEC-8: restrict local copies to a small set of known prefixes
			// (/etc, /tmp, /var, /usr/share) AND follow the WHOLE symlink chain
			// (incl. symlinked parents / multi-hop links) to a final regular
			// file that is itself under the whitelist — defense in depth so a
			// hostile UCI value cannot pull /etc/shadow or similar even via a
			// chained or parent symlink. resolve_local_source returns the
			// validated real path or null; cp then dereferences onto that same
			// verified inode.
			let real = resolve_local_source(target);
			if (real == null) {
				log_err(`fetch_rulesets: ${name} target path '${target}' is outside the whitelist (/etc, /tmp, /var, /usr/share), not a regular file, or a symlink escaping it — rejecting`);
				continue;
			}
			// Local copies are cheap, do them inline. Copy the resolved real
			// path so the verified inode is exactly what reaches the work dir.
			if (system(["cp", "--", real, raw_path]) !== 0) {
				log_err(`fetch_rulesets: cannot read: ${target}`);
				// cp may have left a partial file behind; remove it so
				// stale content never reaches sing-box rule-set decompile.
				helpers.unlink_quiet(raw_path);
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
			helpers.unlink_quiet(m.raw_path);
			continue;
		}
		if (st.size > MAX_BODY) {
			log_err(`fetch_rulesets: ${m.name} body ${st.size} bytes exceeds ${MAX_BODY}, rejecting`);
			helpers.unlink_quiet(m.raw_path);
			continue;
		}
		// Cache-extracted remote rule-sets are always compiled .srs (force
		// binary); local sources use extension-based detection (no UI override).
		let fmt = m.force_binary ? "binary"
		          : helpers.detect_rs_format(m.target);
		if (fmt === "binary") {
			if (system([SINGBOX, "rule-set", "decompile", m.raw_path, "-o", m.out_path]) !== 0) {
				log_err(`fetch_rulesets: decompile failed for ${m.name}`);
				helpers.unlink_quiet(m.raw_path);
				continue;
			}
		} else {
			if (system(["cp", "--", m.raw_path, m.out_path]) !== 0) {
				log_err(`fetch_rulesets: cannot copy source for ${m.name}`);
				helpers.unlink_quiet(m.raw_path);
				continue;
			}
		}
		helpers.unlink_quiet(m.raw_path);
		log(`fetch_rulesets: ${m.name} -> ${m.out_path}`);
	}
	return 0;
}
function any_rulesets_stale(cur, force) {
	for (let name in helpers.sections_of_kind(cur, "ruleset", "nft_rules", "1")) {
		if (helpers.uci_get_or_empty(cur, name, "enabled") === "0") continue;
		let iv = +helpers.uci_get_or_empty(cur, name, "update_interval");
		// !(iv > 0) catches NaN/0/negatives — see any_subs_stale for the bug.
		if (!(iv > 0)) iv = 86400;
		if (helpers.is_stale(`${TMPDIR}/rs_${name}.json`, iv, force)) return true;
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
// One key list per poll (cache_list_keys), not one lookup per tag (S4-5).
function any_tag_cold(db, tags) {
	let keys = cache_list_keys(db);
	// Only the wait loop: an unreadable db keeps us polling until the deadline and
	// then gives up. The reload DECISION is retry_eligible_cold_tags' (SEC-10).
	if (keys == null) return true;     // probe failed → keep waiting
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
// without a guard the loop would busy-spin, re-reading the whole cache.db as
// fast as it can until the deadline. So we also bound the iteration count to
// deadline_s+1 and bail when it's exhausted, guaranteeing termination even if
// `sleep` never paces us.
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
	// SEC-10: a null result is a cache PROBE FAILURE (cache.db absent, truncated,
	// or transiently unreadable mid-upgrade), NOT confirmed evidence the tags are
	// uncompiled. Treating it as "all cold" would trigger a full sing-box
	// stop+start — dropping every live proxy connection — even on a forced UI
	// refresh during a transient hiccup, and even if the tags are in fact warm. A
	// failed probe is not a reason to bounce the daemon: defer the reload (empty
	// eligible set) and surface why, so the next cycle retries once the probe
	// recovers. The cron (non-force) path is already throttled by the cold-backoff
	// sentinel; this closes the forced-refresh edge too.
	//
	// An EMPTY (non-null) key set is the opposite: the db read fine and holds no
	// rule-sets, so the tags really are cold and must still be eligible.
	if (keys == null) {
		// The reason matters to whoever reads the log: "cannot open database" is a
		// router that has not started sing-box yet (self-heals), "invalid database"
		// is a corrupt cache.db that never will (needs a human).
		log(`refresh: cache probe failed (${last_probe_err || "cache.db absent or unreadable"}); deferring reload`);
		return [];
	}
	let out = [];
	for (let t in tags) {
		let cold = (keys[t] !== true);
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
				// A null probe here does NOT mean the tag went warm — it means we
				// cannot tell. We have already issued the reload, so throttle the
				// next one either way: a still-cold tag and an unreadable cache both
				// warrant the backoff sentinel. (SEC-10 forbids a failed probe from
				// TRIGGERING a reload; suppressing a future one is the safe side of
				// the same coin.) Before the reader ran in-process this branch was
				// reached with an empty {} on an unreadable db — the forked shim's
				// exit status was swallowed, so the sentinel always got written.
				// Classifying that failure honestly as null silently dropped it,
				// re-opening the very S4-1 stop+start loop this backoff exists to
				// prevent: no sentinel → still retry-eligible → another init.d reload
				// every cron cycle, dropping every live proxy connection, forever.
				// cmd_fetch_rulesets clears the sentinel on the first successful
				// extract, so a cache that comes back is immediately eligible again.
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
