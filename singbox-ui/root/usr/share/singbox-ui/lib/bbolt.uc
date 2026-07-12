// bbolt.uc — minimal read-only bbolt (BoltDB) reader, ucode port of the former
// no_std Rust bbolt-client. Behavior matches upstream Go bbolt (and the frozen
// golden hashes in bbolt-client/testdata/golden). The whole file is read into
// memory (ucode strings are byte-safe); every key/value is a substr of it.
//
// Ports bbolt-client/src/main.rs:229-501 (the arch-independent parser); the
// ~230 lines of no_std syscall/asm scaffolding it replaced are gone — ucode's
// fs + int64 + print cover open/read/output natively.
//
// int64 caveat: ucode integers are signed int64 but wrap exactly like Rust's
// u64 (proven: FNV-1a64 in test.sh matched Go byte-for-byte). u32 reads stay in
// [0,2^32) so never go negative; u64 reads (pgid/txid/checksum) keep their bit
// pattern. Overflow guards that Rust did with checked_mul are done here in
// pre-divide form (page()) so a forged huge pgid can never wrap past a bound.
//
// ponytail: no flock — bbolt is copy-on-write with two checksummed meta pages
// and select_root() picks the higher-txid valid one, so a concurrent sing-box
// writer can't hand us a torn tree; a half-grown file trips a bounds guard →
// clean error → cron retries. Upgrade path: a native flock helper if fail-fast
// on a busy writer ever matters (it doesn't on a 15-min cron).

'use strict';

let fs = require("fs");

// shared clean-error path — a forged count/pos/ksize/pgid must land here, never
// an OOB abort. THROWS (die), it does not exit(): ucode's exit() is not
// catchable, so an exit() here would take the whole caller down with it. The
// in-process consumer (nft-rulesets.uc) has to turn a corrupt/absent cache.db
// into a null probe and carry on — see SEC-10 there — and the CLI test driver
// (bbolt-client/bbolt-cli.uc) catches this and exits 1 with the same message,
// so the golden harness's exit codes and stderr texts are unchanged.
function bad() { die("invalid database"); }

// bounds-checked little-endian readers. u16/u32 stay in [0,2^32) (positive
// int64); u64 keeps its raw bit pattern (may read as negative — fine, we only
// compare for equality or guard with explicit range checks).
function u16le(b, o) {
	if (o + 2 > length(b)) bad();
	return ord(b, o) | (ord(b, o + 1) << 8);
}
function u32le(b, o) {
	if (o + 4 > length(b)) bad();
	return ord(b, o) | (ord(b, o + 1) << 8) | (ord(b, o + 2) << 16) | (ord(b, o + 3) << 24);
}
function u64le(b, o) {
	if (o + 8 > length(b)) bad();
	let r = 0;
	for (let i = 0; i < 8; i++)
		r |= (ord(b, o + i) << (i * 8));
	return r;
}

// bounds-checked subslice — Rust sub(): end past the buffer (forged pos/ksize)
// is corrupt → bad(). Offsets here are u32-scale, so start+len never wraps int64.
function sub(p, start, len) {
	if (start + len > length(p)) bad();
	return substr(p, start, len);
}

// unsigned byte compare (Go bytes.Compare / memcmp) — NOT ucode's string `<`,
// which would mishandle embedded NUL / high bytes. Returns -1 / 0 / 1.
function bcmp(a, b) {
	let la = length(a), lb = length(b), n = (la < lb) ? la : lb;
	for (let i = 0; i < n; i++) {
		let x = ord(a, i), y = ord(b, i);
		if (x != y) return (x < y) ? -1 : 1;
	}
	return (la == lb) ? 0 : ((la < lb) ? -1 : 1);
}

function fnv1a64(d) {
	let h = 0xcbf29ce484222325;
	for (let i = 0; i < length(d); i++) { h ^= ord(d, i); h *= 0x100000001b3; }
	return h;
}

// read whole db into memory. No flock (see header). Empty/unreadable → throws
// (see bad(): never exit(), the caller must survive an absent cache.db).
function read_db(path) {
	let f = fs.open(path, "r");
	if (!f) die("cannot open database");
	let d = f.read("all") ?? "";
	f.close();
	if (length(d) == 0) die("empty database");
	return d;
}

// [root-bucket pgid, txid] if the meta page at file offset `off` validates.
function read_meta(m, off) {
	let mo = off + 16;                          // 16-byte page header, then meta
	if (mo + 64 > length(m)) return null;
	if (u32le(m, mo) != 0xED0CDAED) return null;    // magic
	if (u32le(m, mo + 4) != 2) return null;         // version
	if (fnv1a64(substr(m, mo, 56)) != u64le(m, mo + 56)) return null; // checksum
	return [u64le(m, mo + 16), u64le(m, mo + 48)];  // root.root, txid
}

function select_root(m, ps) {
	let a = read_meta(m, 0), b = read_meta(m, ps);
	if (a && b) return (b[1] > a[1]) ? b[0] : a[0];
	if (a) return a[0];
	if (b) return b[0];
	bad();
}

// page size: trust meta0's field only if meta0 validates; else probe sizes
// (bbolt getPageSize() crash-recovery). Clean exit on too-small / non-bbolt.
function page_size(m) {
	if (read_meta(m, 0)) {
		let ps = u32le(m, 24);
		if (ps >= 512 && ps <= 65536 && (ps & (ps - 1)) == 0) return ps;
	}
	let p = 512;
	while (p <= 65536) {
		if (read_meta(m, p)) return p;
		p <<= 1;
	}
	bad();
}

// full page span (header + data + overflow), with corruption guards.
function page(m, ps, id) {
	let mlen = length(m);
	// Reject a forged pgid before multiplying: id*ps could wrap int64. A valid
	// page needs id*ps + 16 <= mlen, i.e. id <= (mlen-16)/ps. id<0 catches a
	// bit63-set forged pgid; the range check catches the rest (Rust checked_mul).
	if (id < 0 || id > int((mlen - 16) / ps)) bad();
	let off = id * ps;
	// FastCheck: the page must self-identify as `id`, else a forged pgid could
	// alias another in-bounds page (wrong answer).
	if (u64le(m, off) != id) bad();
	let overflow = u32le(m, off + 12);
	let end = off + (overflow + 1) * ps;
	if (end > mlen) end = mlen;                 // bbolt ignores overflow on read
	return substr(m, off, end - off);
}

// branch-element key (element: pos@eo, ksize@eo+4, pgid@eo+8)
function bkey(p, i) {
	let eo = 16 + i * 16;
	return sub(p, eo + u32le(p, eo), u32le(p, eo + 4));
}
// leaf-element key (element: flags@eo, pos@eo+4, ksize@eo+8, vsize@eo+12)
function lkey(p, i) {
	let eo = 16 + i * 16;
	return sub(p, eo + u32le(p, eo + 4), u32le(p, eo + 8));
}

// Total pages visited by the current walk(). The depth cap alone bounds the
// tree's HEIGHT, not its fan-out: a forged chain of ~63 branch pages that each
// list two children pointing at the next page stays under depth 64 while
// demanding ~2^63 visits — a clean-looking read that never returns and hangs the
// cron refresh. A real cache.db has a few thousand pages, so a flat visit budget
// costs nothing and turns that into the same "invalid database" error as any
// other corruption.
//
// The budget is per top-level walk (reset at depth 0), not process-scoped. That is
// HARDENING, not a live-bug fix, and the distinction is worth keeping straight:
// measured, one rule_set walk costs ~4 page visits and a whole refresh ~13 walks
// (~52) against a 200000 budget — ~3800x of headroom, so no counter alive today
// could accumulate its way to a false "invalid database". What died is the
// ASSUMPTION the old module-scoped counter rested on ("the CLI shim is a fresh
// process per read"): the shim is gone, nft-rulesets.uc calls walk() in-process,
// and wait_for_tags walks once a second. Per-walk is what the paragraph above
// already claims the budget is, and it is the only thing that keeps this guard
// honest if anything ever walks repeatedly in a long-lived process.
let _visits = 0;
const MAX_VISITS = 200000;

// DFS the B+tree, pushing keys into `acc`. buckets_only => only sub-bucket
// leaf entries. `depth` bounds descent so a cyclic/forged branch pgid is a
// clean error, not unbounded recursion. bbolt trees never approach 64.
function walk(m, ps, p, buckets_only, depth, acc) {
	if (depth > 64) bad();
	if (depth == 0) _visits = 0;
	if (++_visits > MAX_VISITS) bad();
	let flags = u16le(p, 8), count = u16le(p, 10);
	if (flags & 0x01) {
		for (let i = 0; i < count; i++)
			walk(m, ps, page(m, ps, u64le(p, 16 + i * 16 + 8)), buckets_only, depth + 1, acc);
	} else {
		for (let i = 0; i < count; i++) {
			let eo = 16 + i * 16, lflags = u32le(p, eo);
			if (!buckets_only || (lflags & 0x01))
				push(acc, sub(p, eo + u32le(p, eo + 4), u32le(p, eo + 8)));
		}
	}
}

// find `target` in a B+tree; [leaf-flags, value-bytes] on exact match, else null.
function search(m, ps, p, target, depth) {
	if (depth > 64) bad();
	let flags = u16le(p, 8), count = u16le(p, 10);
	if (flags & 0x01) {
		// branch: first index with key >= target, then step back one unless exact
		let lo = 0, hi = count;
		while (lo < hi) { let mid = int((lo + hi) / 2); if (bcmp(bkey(p, mid), target) < 0) lo = mid + 1; else hi = mid; }
		let idx = (lo < count && bcmp(bkey(p, lo), target) == 0) ? lo : ((lo > 0) ? lo - 1 : 0);
		return search(m, ps, page(m, ps, u64le(p, 16 + idx * 16 + 8)), target, depth + 1);
	}
	// leaf: exact match only
	let lo = 0, hi = count;
	while (lo < hi) { let mid = int((lo + hi) / 2); if (bcmp(lkey(p, mid), target) < 0) lo = mid + 1; else hi = mid; }
	if (lo < count && bcmp(lkey(p, lo), target) == 0) {
		let eo = 16 + lo * 16;
		return [u32le(p, eo), sub(p, eo + u32le(p, eo + 4) + u32le(p, eo + 8), u32le(p, eo + 12))];
	}
	return null;
}

// resolve a named top-level bucket to {page:pgid} or {inline:bytes}, or null.
function find_bucket(m, ps, root, name) {
	let r = search(m, ps, page(m, ps, root), name, 0);
	if (r && (r[0] & 0x01)) {
		let val = r[1];
		let broot = u64le(val, 0);              // bucket{root:u64, sequence:u64}; needs len>=8
		if (broot != 0) return { page: broot };
		if (length(val) >= 16) return { inline: substr(val, 16) };
		bad();                                  // forged: value too short
	}
	return null;
}

// Go encoding/binary.Uvarint: [value, bytes_read]; bytes_read == 0 on failure.
function uvarint(b) {
	let x = 0, s = 0, n = length(b);
	for (let i = 0; i < n && i < 10; i++) {
		let c = ord(b, i);
		if (c < 0x80) {
			if (i == 9 && c > 1) return [0, 0];     // u64 overflow
			return [x | (c << s), i + 1];
		}
		x |= (c & 0x7f) << s;
		s += 7;
	}
	return [0, 0];                              // incomplete
}

// strip the sing-box SavedRuleSet envelope -> raw .srs payload (-r path), or null.
function unwrap_ruleset(b) {
	if (length(b) == 0 || ord(b, 0) != 1) { warn("unexpected SavedRuleSet envelope version\n"); return null; }
	let uv = uvarint(substr(b, 1)), n = uv[0], off = uv[1];
	if (off == 0) { warn("bad content-length varint\n"); return null; }
	let start = 1 + off;
	let remaining = length(b) - start;
	// n<0 catches a bit63-set forged length; n>remaining the rest (Rust checked in u64).
	if (n <= 0 || n > remaining) {
		warn(sprintf("content length %u out of range (blob %u bytes)\n", n, length(b)));
		return null;
	}
	return substr(b, start, n);
}

return {
	read_db, page_size, select_root, page, walk, search, find_bucket, unwrap_ruleset,
};
