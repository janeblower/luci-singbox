#![no_std]
#![no_main]

//! Minimal read-only bbolt reader (behavior matches the upstream Go bbolt reference):
//!   <db>                   list top-level buckets
//!   <db> <bucket>          list keys in bucket
//!   <db> <bucket> <key>    write raw value bytes to stdout
//!   -r <db> <bucket> <key> strip the sing-box SavedRuleSet envelope -> .srs payload
//! No libc, no heap: the file is mmap'd PROT_READ and every key/value is a slice
//! into the mapping. x86_64 and aarch64 Linux (the syscall layer is arch-gated).

use core::arch::{asm, global_asm};

// ---------------- raw Linux syscalls ----------------
// Only the numbers, the `syscall6` instruction, and `_start` are arch-specific;
// the parser and I/O below are arch-independent. Supported: x86_64, aarch64.
#[cfg(target_arch = "x86_64")]
mod nr {
    pub const WRITE: usize = 1;
    pub const OPENAT: usize = 257;
    pub const LSEEK: usize = 8;
    pub const MMAP: usize = 9;
    pub const FLOCK: usize = 73;
    pub const NANOSLEEP: usize = 35;
    pub const EXIT_GROUP: usize = 231;
}
#[cfg(target_arch = "aarch64")]
mod nr {
    pub const WRITE: usize = 64;
    pub const OPENAT: usize = 56;
    pub const LSEEK: usize = 62;
    pub const MMAP: usize = 222;
    pub const FLOCK: usize = 32;
    pub const NANOSLEEP: usize = 101;
    pub const EXIT_GROUP: usize = 94;
}

#[cfg(target_arch = "x86_64")]
#[inline]
unsafe fn syscall6(n: usize, a1: usize, a2: usize, a3: usize,
                   a4: usize, a5: usize, a6: usize) -> isize {
    let ret: isize;
    asm!(
        "syscall",
        inlateout("rax") n => ret,
        in("rdi") a1, in("rsi") a2, in("rdx") a3,
        in("r10") a4, in("r8") a5, in("r9") a6,
        out("rcx") _, out("r11") _,
        // NOT preserves_flags: the kernel may clobber EFLAGS across `syscall`.
        options(nostack),
    );
    ret
}

#[cfg(target_arch = "aarch64")]
#[inline]
unsafe fn syscall6(n: usize, a1: usize, a2: usize, a3: usize,
                   a4: usize, a5: usize, a6: usize) -> isize {
    let ret: isize;
    asm!(
        "svc #0",
        in("x8") n,
        inlateout("x0") a1 => ret,
        in("x1") a2, in("x2") a3, in("x3") a4, in("x4") a5, in("x5") a6,
        options(nostack),
    );
    ret
}

const AT_FDCWD: usize = (-100isize) as usize;
const LOCK_SH: usize = 1;
const LOCK_NB: usize = 4;
const EAGAIN: isize = -11;

unsafe fn sys_openat(path: *const u8) -> isize { syscall6(nr::OPENAT, AT_FDCWD, path as usize, 0, 0, 0, 0) }
unsafe fn sys_write(fd: usize, buf: *const u8, len: usize) -> isize { syscall6(nr::WRITE, fd, buf as usize, len, 0, 0, 0) }
unsafe fn sys_lseek_end(fd: usize) -> isize { syscall6(nr::LSEEK, fd, 0, 2, 0, 0, 0) }
unsafe fn sys_mmap_read(fd: usize, len: usize) -> isize { syscall6(nr::MMAP, 0, len, 1, 2, fd, 0) }
unsafe fn sys_flock(fd: usize, op: usize) -> isize { syscall6(nr::FLOCK, fd, op, 0, 0, 0, 0) }
unsafe fn sys_nanosleep_ms(ms: i64) {
    let ts = [ms / 1000, (ms % 1000) * 1_000_000];
    syscall6(nr::NANOSLEEP, ts.as_ptr() as usize, 0, 0, 0, 0, 0);
}
unsafe fn sys_exit(code: usize) -> ! { syscall6(nr::EXIT_GROUP, code, 0, 0, 0, 0, 0); loop {} }

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! { unsafe { sys_exit(134) } }

// ---------------- entry: pass the argv-block pointer (argc at [sp]) to rust_entry ----------------
#[cfg(target_arch = "x86_64")]
global_asm!(
    ".global _start",
    "_start:",
    "xor rbp, rbp",
    "mov rdi, rsp",
    "and rsp, -16",
    "call rust_entry",
);
#[cfg(target_arch = "aarch64")]
global_asm!(
    ".global _start",
    "_start:",
    "mov x0, sp", // argv-block pointer (argc at [sp]); sp is already 16-aligned at entry
    "bl rust_entry",
);

#[no_mangle]
unsafe extern "C" fn rust_entry(sp: *const usize) -> ! {
    let argc = *sp as usize;
    let argv = sp.add(1) as *const *const u8;
    sys_exit(run(argc, argv) as usize)
}

// ---------------- output helpers ----------------
fn out(fd: usize, mut b: &[u8]) {
    while !b.is_empty() {
        let n = unsafe { sys_write(fd, b.as_ptr(), b.len()) };
        if n <= 0 { unsafe { sys_exit(1) } }
        b = &b[n as usize..];
    }
}
fn line(b: &[u8]) { out(1, b); out(1, b"\n"); }
fn err(b: &[u8]) { out(2, b); }
fn err_quoted(prefix: &[u8], name: &[u8]) {
    out(2, prefix);
    out(2, b"\"");
    out(2, name);
    out(2, b"\"\n");
}
fn err_u64(mut n: u64) {
    if n == 0 { out(2, b"0"); return; }
    let mut buf = [0u8; 20];
    let mut i = 20;
    while n > 0 { i -= 1; buf[i] = b'0' + (n % 10) as u8; n /= 10; }
    out(2, &buf[i..]);
}

unsafe fn cstr(p: *const u8) -> &'static [u8] {
    let mut len = 0;
    while *p.add(len) != 0 { len += 1; }
    core::slice::from_raw_parts(p, len)
}

// ---------------- little-endian reads ----------------
fn u16le(b: &[u8], o: usize) -> u16 { u16::from_le_bytes([b[o], b[o + 1]]) }
fn u32le(b: &[u8], o: usize) -> u32 { u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]]) }
fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3], b[o + 4], b[o + 5], b[o + 6], b[o + 7]])
}

// ---------------- open / meta / pages ----------------
unsafe fn open_db(path: *const u8) -> &'static [u8] {
    let fd = sys_openat(path);
    if fd < 0 { err(b"cannot open database\n"); sys_exit(1); }
    let fd = fd as usize;
    // shared lock with ~1s timeout: fail fast (not hang) if a writer holds it.
    let mut tries = 0;
    loop {
        let r = sys_flock(fd, LOCK_SH | LOCK_NB);
        if r == 0 { break; }
        if r == EAGAIN {
            if tries >= 20 { err(b"timeout\n"); sys_exit(1); }
            tries += 1;
            sys_nanosleep_ms(50);
            continue;
        }
        err(b"cannot lock database\n");
        sys_exit(1);
    }
    let size = sys_lseek_end(fd);
    if size <= 0 { err(b"empty database\n"); sys_exit(1); }
    let addr = sys_mmap_read(fd, size as usize);
    if addr < 0 && addr > -4096 { err(b"cannot map database\n"); sys_exit(1); }
    core::slice::from_raw_parts(addr as *const u8, size as usize)
}

fn fnv1a64(d: &[u8]) -> u64 {
    let mut h = 0xcbf29ce484222325u64;
    let mut i = 0;
    while i < d.len() { h ^= d[i] as u64; h = h.wrapping_mul(0x100000001b3); i += 1; }
    h
}

// returns (root-bucket pgid, txid) if the meta at file offset `off` is valid
fn read_meta(m: &[u8], off: usize) -> Option<(u64, u64)> {
    let mo = off + 16; // page header is 16 bytes; meta begins at the page data
    if mo + 64 > m.len() { return None; }
    if u32le(m, mo) != 0xED0CDAED { return None; }   // magic
    if u32le(m, mo + 4) != 2 { return None; }         // version
    if fnv1a64(&m[mo..mo + 56]) != u64le(m, mo + 56) { return None; } // checksum
    Some((u64le(m, mo + 16), u64le(m, mo + 48)))      // root.root, txid
}

fn select_root(m: &[u8], ps: usize) -> u64 {
    match (read_meta(m, 0), read_meta(m, ps)) {
        (Some(a), Some(b)) => if b.1 > a.1 { b.0 } else { a.0 },
        (Some(a), None) => a.0,
        (None, Some(b)) => b.0,
        (None, None) => { err(b"invalid database\n"); unsafe { sys_exit(1) } }
    }
}

// Determine the page size. Trust meta0's pageSize field only if meta0 itself
// validates (its FNV checksum covers the field); otherwise the writer may have
// torn meta0 mid-write, so locate the surviving meta by probing page sizes —
// matching bbolt's getPageSize() crash-recovery path. Also yields a clean
// "invalid database" exit on a too-small / non-bbolt file (no OOB read).
fn page_size(m: &[u8]) -> usize {
    if read_meta(m, 0).is_some() {
        return u32le(m, 24) as usize;
    }
    let mut p = 512usize;
    while p <= 65536 {
        if read_meta(m, p).is_some() { return p; }
        p <<= 1;
    }
    err(b"invalid database\n");
    unsafe { sys_exit(1) }
}

// full page span (header + data + any overflow pages), with corruption guards
fn page(m: &[u8], ps: usize, id: u64) -> &[u8] {
    // reject ids that overflow usize or fall outside the mapping (corrupt db)
    let off = match (id as usize).checked_mul(ps) {
        Some(v) if v + 16 <= m.len() => v,
        _ => { err(b"invalid database\n"); unsafe { sys_exit(1) } }
    };
    // bbolt FastCheck: a page must self-identify as the requested id, else a
    // wrapped/forged pgid could alias a different in-bounds page (wrong answer).
    if u64le(m, off) != id { err(b"invalid database\n"); unsafe { sys_exit(1) } }
    let overflow = u32le(m, off + 12) as usize;
    let mut end = off + (overflow + 1) * ps;
    if end > m.len() { end = m.len(); } // bbolt ignores overflow on the read path
    &m[off..end]
}

// DFS a B+tree, printing keys. buckets_only => only leaf entries flagged as sub-buckets.
// `depth` bounds the descent so a cyclic/forged branch pgid yields a clean exit
// instead of unbounded recursion (stack-overflow SIGSEGV). bbolt trees never approach 64.
fn walk(m: &[u8], ps: usize, p: &[u8], buckets_only: bool, depth: u32) {
    if depth > 64 { err(b"invalid database\n"); unsafe { sys_exit(1) } }
    let flags = u16le(p, 8);
    let count = u16le(p, 10) as usize;
    let mut i = 0;
    if flags & 0x01 != 0 {
        while i < count {
            let child = u64le(p, 16 + i * 16 + 8);
            walk(m, ps, page(m, ps, child), buckets_only, depth + 1);
            i += 1;
        }
    } else {
        while i < count {
            let eo = 16 + i * 16;
            let lflags = u32le(p, eo);
            if !buckets_only || (lflags & 0x01 != 0) {
                let pos = u32le(p, eo + 4) as usize;
                let ks = u32le(p, eo + 8) as usize;
                line(&p[eo + pos..eo + pos + ks]);
            }
            i += 1;
        }
    }
}

fn bkey(p: &[u8], i: usize) -> &[u8] {
    let eo = 16 + i * 16;
    let pos = u32le(p, eo) as usize;
    let ks = u32le(p, eo + 4) as usize;
    &p[eo + pos..eo + pos + ks]
}
fn lkey(p: &[u8], i: usize) -> &[u8] {
    let eo = 16 + i * 16;
    let pos = u32le(p, eo + 4) as usize;
    let ks = u32le(p, eo + 8) as usize;
    &p[eo + pos..eo + pos + ks]
}

// find `target` in a B+tree; returns (leaf flags, value bytes) on exact match.
// `depth` bounds the descent (cyclic/forged branch pgid => clean exit, not a hang).
fn search<'a>(m: &'a [u8], ps: usize, p: &'a [u8], target: &[u8], depth: u32) -> Option<(u32, &'a [u8])> {
    if depth > 64 { err(b"invalid database\n"); unsafe { sys_exit(1) } }
    let flags = u16le(p, 8);
    let count = u16le(p, 10) as usize;
    if flags & 0x01 != 0 {
        // branch: first index with key >= target, then step back one unless exact
        let (mut lo, mut hi) = (0usize, count);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if bkey(p, mid) < target { lo = mid + 1 } else { hi = mid }
        }
        let idx = if lo < count && bkey(p, lo) == target { lo }
                  else if lo > 0 { lo - 1 } else { 0 };
        let child = u64le(p, 16 + idx * 16 + 8);
        search(m, ps, page(m, ps, child), target, depth + 1)
    } else {
        // leaf: exact match only
        let (mut lo, mut hi) = (0usize, count);
        while lo < hi {
            let mid = (lo + hi) / 2;
            if lkey(p, mid) < target { lo = mid + 1 } else { hi = mid }
        }
        if lo < count && lkey(p, lo) == target {
            let eo = 16 + lo * 16;
            let lflags = u32le(p, eo);
            let pos = u32le(p, eo + 4) as usize;
            let ks = u32le(p, eo + 8) as usize;
            let vs = u32le(p, eo + 12) as usize;
            Some((lflags, &p[eo + pos + ks..eo + pos + ks + vs]))
        } else {
            None
        }
    }
}

enum BRoot<'a> { Page(u64), Inline(&'a [u8]) }

// resolve a named top-level bucket to its root page or inline leaf buffer
fn find_bucket<'a>(m: &'a [u8], ps: usize, root: u64, name: &[u8]) -> Option<BRoot<'a>> {
    match search(m, ps, page(m, ps, root), name, 0) {
        Some((flags, val)) if flags & 0x01 != 0 => {
            let broot = u64le(val, 0); // bucket{ root: u64, sequence: u64 }
            if broot != 0 { Some(BRoot::Page(broot)) } else { Some(BRoot::Inline(&val[16..])) }
        }
        _ => None,
    }
}

// ---------------- SavedRuleSet envelope (-r) ----------------
// Go encoding/binary.Uvarint: returns (value, bytes_read); bytes_read == 0 on failure.
fn uvarint(b: &[u8]) -> (u64, usize) {
    let mut x = 0u64;
    let mut s = 0u32;
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c < 0x80 {
            if i > 9 || (i == 9 && c > 1) { return (0, 0); } // u64 overflow
            return (x | (c as u64) << s, i + 1);
        }
        x |= ((c & 0x7f) as u64) << s;
        s += 7;
        i += 1;
    }
    (0, 0) // incomplete
}

fn unwrap_ruleset(b: &[u8]) -> Option<&[u8]> {
    if b.is_empty() || b[0] != 1 {
        err(b"unexpected SavedRuleSet envelope version\n");
        return None;
    }
    let (n, off) = uvarint(&b[1..]);
    if off == 0 {
        err(b"bad content-length varint\n");
        return None;
    }
    let start = 1 + off;
    let end = start + n as usize;
    if n == 0 || end > b.len() {
        err(b"content length ");
        err_u64(n);
        err(b" out of range (blob ");
        err_u64(b.len() as u64);
        err(b" bytes)\n");
        return None;
    }
    Some(&b[start..end])
}

// ---------------- mode dispatch ----------------
unsafe fn run(argc: usize, argv: *const *const u8) -> i32 {
    let mut base = 1usize;
    let mut ruleset = false;
    if argc > 1 && cstr(*argv.add(1)) == b"-r" { ruleset = true; base = 2; }
    let rem = argc.saturating_sub(base);
    if rem == 0 { err(b"usage: bbolt-client [-r] <db> [bucket] [key]\n"); return 2; }

    let m = open_db(*argv.add(base));
    let ps = page_size(m);
    let root = select_root(m, ps);

    if rem == 1 {
        walk(m, ps, page(m, ps, root), true, 0);
        return 0;
    }

    let bname = cstr(*argv.add(base + 1));
    let bref = match find_bucket(m, ps, root, bname) {
        Some(r) => r,
        None => { err_quoted(b"no bucket ", bname); return 1; }
    };
    let bp: &[u8] = match bref { BRoot::Page(pg) => page(m, ps, pg), BRoot::Inline(b) => b };

    if rem == 2 {
        walk(m, ps, bp, false, 0);
        return 0;
    }

    let kname = cstr(*argv.add(base + 2));
    let val = match search(m, ps, bp, kname, 0) {
        Some((flags, v)) if flags & 0x01 == 0 => v, // plain key only; sub-bucket => no value
        _ => { err_quoted(b"no key ", kname); return 1; }
    };
    let payload = if ruleset {
        match unwrap_ruleset(val) { Some(p) => p, None => return 1 }
    } else {
        val
    };
    out(1, payload);
    0
}
