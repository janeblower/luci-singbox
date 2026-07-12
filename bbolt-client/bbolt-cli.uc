#!/usr/bin/ucode
// bbolt-cli.uc — TEST DRIVER for lib/bbolt.uc. NOT part of any package.
//
// Production (singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc) calls the
// reader in-process: it is a ucode module on nft-rulesets.uc's own -L path, so
// there is nothing to fork. This driver exists only so the golden harness
// (./test.sh) can drive the same reader from a shell, one process per read, and
// diff its stdout against the frozen Go-bbolt hashes in testdata/golden/.
//
// It used to live at singbox-ui/root/usr/libexec/singbox-ui/bbolt-client and
// ship in the package, argv-compatible with a per-arch Rust binary that no
// longer exists. The argv surface is kept as-is because test.sh speaks it:
//   <db>                   list top-level buckets
//   <db> <bucket>          list keys in bucket
//   <db> <bucket> <key>    write raw value bytes to stdout
//   -r <db> <bucket> <key> strip the SavedRuleSet envelope -> .srs payload
//
// Bare shebang, and NOT executable (mode 644) on purpose: require("bbolt") needs
// a -L, so `./bbolt-cli.uc` could never work. Run it the way test.sh does —
// `ucode -L <lib> bbolt-cli.uc`.
'use strict';

let bb = require("bbolt");

function print_keys(m, ps, page_bytes, buckets_only) {
	let acc = [];
	bb.walk(m, ps, page_bytes, buckets_only, 0, acc);
	for (let k in acc) { print(k); print("\n"); }
}

function main() {
	let args = ARGV;
	let ruleset = false, i = 0;
	if (length(args) >= 1 && args[0] == "-r") { ruleset = true; i = 1; }
	if (length(args) - i < 1) { warn("usage: bbolt-client [-r] <db> [bucket] [key]\n"); exit(2); }

	let m = bb.read_db(args[i]);
	let ps = bb.page_size(m);
	let root = bb.select_root(m, ps);

	if (length(args) - i == 1) { print_keys(m, ps, bb.page(m, ps, root), true); exit(0); }

	let bname = args[i + 1];
	let bref = bb.find_bucket(m, ps, root, bname);
	if (bref == null) { warn(sprintf('no bucket "%s"\n', bname)); exit(1); }
	let bp = (bref.page != null) ? bb.page(m, ps, bref.page) : bref.inline;

	if (length(args) - i == 2) { print_keys(m, ps, bp, false); exit(0); }

	let kname = args[i + 2];
	let r = bb.search(m, ps, bp, kname, 0);
	// plain key only; a sub-bucket entry (flags&1) has no value
	if (r == null || (r[0] & 0x01) != 0) { warn(sprintf('no key "%s"\n', kname)); exit(1); }

	let payload = ruleset ? bb.unwrap_ruleset(r[1]) : r[1];
	if (payload == null) exit(1);
	print(payload);
	exit(0);
}

// The reader THROWS on a corrupt/absent db (lib/bbolt.uc bad()) so that its
// in-process caller can survive one; a CLI cannot, so turn it back into the
// exit(1) + one-line stderr the harness asserts on. exit() is not catchable in
// ucode, so main()'s own exit(0)/exit(1)/exit(2) pass straight through.
try {
	main();
} catch (e) {
	warn((e.message ?? "invalid database") + "\n");
	exit(1);
}
