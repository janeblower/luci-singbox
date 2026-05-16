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

let fs  = require("fs");
let uci_mod = require("uci");

function log(msg)     { warn(msg + "\n"); }
function log_err(msg) { warn(msg + "\n"); }

// uci_get_or_empty(cur, section, opt) — never throws, returns "".
function uci_get_or_empty(cur, section, opt) {
	let v = cur.get("singbox-ui", section, opt);
	return (v == null) ? "" : (type(v) === "array" ? (length(v) ? v[0] : "") : v);
}

// sections_where(cur, opt, value) — list of section names where opt == value.
function sections_where(cur, opt, value) {
	let out = [];
	cur.foreach("singbox-ui", null, function (s) {
		if (s[opt] === value) push(out, s[".name"]);
	});
	return out;
}

// http_download(url, outpath, opts) -> bool
// opts: { timeout (s), interface, user_agent }
function http_download(url, outpath, opts) {
	opts = opts || {};
	let argv = [
		"curl", "-sfL",
		"--max-time", `${opts.timeout ?? 15}`,
		"-A", opts.user_agent || DEFAULT_UA,
		"-o", outpath,
	];
	if (opts.interface) {
		push(argv, "--interface", opts.interface);
	}
	push(argv, url);
	let rc = system(argv);
	if (rc !== 0) return false;
	let st = fs.stat(outpath);
	return st && st.size > 0;
}

// Subscription bodies are usually base64-encoded plaintext containing one
// proxy URL per line; some servers return plaintext directly. Decode only
// when the decoded payload looks like proxy URLs (contains "://"). This
// keeps plaintext bodies that happen to use only base64-alphabet chars
// from being silently mangled.
function try_b64_decode(s) {
	let dec = null;
	try { dec = b64dec(s); } catch (e) { /* invalid base64 */ }
	if (dec != null && length(dec) > 0 && index(dec, "://") >= 0)
		return dec;
	return s;
}

function cmd_fetch_subs(cur) {
	let names = sections_where(cur, "proxy_type", "subscription");
	if (!length(names)) {
		log_err("fetch_subs: no subscription outbounds configured");
		return 0;
	}

	for (let name in names) {
		if (uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_subs: ${name} disabled, skipping`);
			continue;
		}
		let url = uci_get_or_empty(cur, name, "sub_url");
		if (url === "") {
			log_err(`fetch_subs: ${name} has no sub_url, skipping`);
			continue;
		}

		let via = uci_get_or_empty(cur, name, "sub_update_via");
		let iface = null;
		if (via !== "" && via !== "direct") {
			iface = uci_get_or_empty(cur, via, "interface");
			if (iface === "") {
				log_err(`fetch_subs: outbound '${via}' has no interface`);
				continue;
			}
		}

		let raw_path = `${TMPDIR}/sub_${name}.raw`;
		let out_path = `${TMPDIR}/sub_${name}.txt`;
		if (!http_download(url, raw_path, { timeout: 15, interface: iface })) {
			log_err(`fetch_subs: download failed for ${name} (${url})`);
			continue;
		}

		let raw_fd = fs.open(raw_path, "r");
		if (!raw_fd) {
			log_err(`fetch_subs: cannot read ${raw_path}`);
			fs.unlink(raw_path);
			continue;
		}
		let raw = raw_fd.read("all") ?? "";
		raw_fd.close();
		fs.unlink(raw_path);
		if (length(raw) === 0) {
			log_err(`fetch_subs: empty body for ${name}`);
			continue;
		}

		let decoded = try_b64_decode(raw);
		let urls = [];
		for (let line in split(decoded, "\n")) {
			let t = trim(line);
			if (t !== "" && match(t, /^[a-z][a-z0-9+.-]*:\/\//))
				push(urls, t);
		}
		if (!length(urls)) {
			log_err(`fetch_subs: no valid proxy URL in response for ${name}`);
			continue;
		}

		let out_fd = fs.open(out_path, "w");
		if (!out_fd) {
			log_err(`fetch_subs: cannot write ${out_path}`);
			continue;
		}
		for (let u in urls) out_fd.write(u + "\n");
		out_fd.close();
		log(`fetch_subs: ${name} -> ${out_path} (${length(urls)} urls)`);
	}
	return 0;
}
// detect_format(target, override) — auto-detect from extension; override wins.
function detect_format(target, override) {
	if (override === "binary" || override === "source") return override;
	let lower = lc(target);
	if (substr(lower, -4) === ".srs")   return "binary";
	if (substr(lower, -5) === ".json")  return "source";
	return "binary";
}

function fetch_one_ruleset(cur, name) {
	let rs_type = uci_get_or_empty(cur, name, "type");
	let target = "";
	if (rs_type === "remote") target = uci_get_or_empty(cur, name, "url");
	else if (rs_type === "local") target = uci_get_or_empty(cur, name, "path");
	if (target === "") {
		log_err(`fetch_rulesets: ${name} has no ${rs_type === "local" ? "path" : "url"}, skipping`);
		return;
	}

	let fmt = detect_format(target, uci_get_or_empty(cur, name, "format"));
	let raw_path = `${TMPDIR}/rs_${name}.raw`;
	let out_path = `${TMPDIR}/rs_${name}.json`;

	if (rs_type === "remote") {
		if (!http_download(target, raw_path, { timeout: 30 })) {
			log_err(`fetch_rulesets: download failed: ${target}`);
			return;
		}
	} else if (rs_type === "local") {
		// Copy with cp(1) to keep the same set of dependencies (no fs.copy in ucode).
		if (system(["cp", "--", target, raw_path]) !== 0) {
			log_err(`fetch_rulesets: cannot read: ${target}`);
			return;
		}
	} else {
		log_err(`fetch_rulesets: unknown type '${rs_type}' for ${name}`);
		return;
	}

	if (fmt === "binary") {
		if (system([SINGBOX, "rule-set", "decompile", raw_path, "-o", out_path]) !== 0) {
			log_err(`fetch_rulesets: decompile failed for ${name}`);
			fs.unlink(raw_path);
			return;
		}
	} else {
		if (system(["cp", "--", raw_path, out_path]) !== 0) {
			log_err(`fetch_rulesets: cannot copy source for ${name}`);
			fs.unlink(raw_path);
			return;
		}
	}
	fs.unlink(raw_path);
	log(`fetch_rulesets: ${name} -> ${out_path}`);
}

function cmd_fetch_rulesets(cur) {
	let names = sections_where(cur, "nft_rules", "1");
	if (!length(names)) {
		log_err("fetch_rulesets: no rule-sets configured (nft_rules=1)");
		return 0;
	}
	for (let name in names) {
		if (uci_get_or_empty(cur, name, "enabled") === "0") {
			log_err(`fetch_rulesets: ${name} disabled, skipping`);
			continue;
		}
		fetch_one_ruleset(cur, name);
	}
	return 0;
}
// is_stale(path, interval_s, force) -> bool. Missing file / zero interval / no
// interval => stale. Matches refresh.sh behaviour.
function is_stale(path, interval_s, force) {
	if (force) return true;
	let st = fs.stat(path);
	if (!st) return true;
	if (interval_s == null || interval_s === 0) return true;
	return (time() - st.mtime) >= interval_s;
}

function any_subs_stale(cur, force) {
	for (let name in sections_where(cur, "proxy_type", "subscription")) {
		if (uci_get_or_empty(cur, name, "enabled") === "0") continue;
		let iv = +uci_get_or_empty(cur, name, "sub_interval");
		if (iv === 0) iv = 3600;
		if (is_stale(`${TMPDIR}/sub_${name}.txt`, iv, force)) return true;
	}
	return false;
}

function any_rulesets_stale(cur, force) {
	for (let name in sections_where(cur, "nft_rules", "1")) {
		if (uci_get_or_empty(cur, name, "enabled") === "0") continue;
		let iv = +uci_get_or_empty(cur, name, "update_interval");
		if (iv === 0) iv = 86400;
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
