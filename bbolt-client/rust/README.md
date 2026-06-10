# bbolt-client-rs

Rust port of [`../bbolt-client`](../) (Go): a `#![no_std]`, **no-libc**,
raw-syscall, read-only bbolt reader, built for minimal size.

**~7.3 KB** static binary vs the Go tool's 674 KB (UPX'd) — roughly **90× smaller** —
with byte-for-byte identical behavior.

## Build (nightly required)

    ./build.sh        # -> ./bbolt-client-rs  (static, x86_64)
    make test         # build + byte-parity diff vs the Go tool (../cache.db + stress fixture)

Needs a nightly toolchain with `rust-src` (pinned in `rust-toolchain.toml`); the
build uses `-Z build-std=core` with `panic = "immediate-abort"` and links with
`-nostdlib` so no libc or CRT is pulled in. The binary is a fully static ELF with
no `PT_INTERP`, so the single `linux/amd64` binary runs on both glibc hosts and
musl OpenWrt x86/64.

**x86_64 Linux only.** The syscall layer uses the x86_64 `syscall` instruction and
hardcoded syscall numbers; there is no `make GOARCH=arm64` equivalent (the syscall
module would need an arch-gated variant).

## Usage (identical to the Go tool)

    bbolt-client-rs <db>                   # list buckets
    bbolt-client-rs <db> <bucket>          # list keys in bucket
    bbolt-client-rs <db> <bucket> <key>    # raw value bytes to stdout
    bbolt-client-rs -r <db> <bucket> <key> # strip SavedRuleSet envelope -> .srs

Opens read-only with a shared lock and ~1s timeout: if sing-box holds the file
(exclusive lock) it prints `timeout` (exit 1) instead of hanging — copy the db and
read the copy. Exit codes: `0` ok, `1` error (missing file/bucket/key, lock), `2`
bad args.

> Note: the OS-error text for a missing file / lock / mmap failure is simplified
> (a full errno→string table is not worth the bytes). Only the **exit codes** match
> the Go tool there; the bucket/key/value/`-r`/usage/`no bucket`/`no key`/`timeout`
> outputs match exactly, byte-for-byte.

### Robustness on corrupt input

A malformed or truncated db is reported as `invalid database` (exit 1) — never a
crash. The parser bounds-checks page spans, rejects page ids that overflow or fail
bbolt's self-identity check (`FastCheck`), and depth-limits the B+tree descent, so a
truncated copy or a crafted db (cyclic page links, a wrapping `pgid`, a bogus
`overflow` field) yields a clean exit instead of a SIGSEGV/SIGILL or a wrong answer.
These cases are covered by `test-parity.sh` against the fixtures in `testdata/`
(`gen_corrupt.go`).

One intentional divergence: a `-r` envelope whose declared content length is ≥ 2⁶³
gets a clean `content length … out of range` error here (exit 1), whereas the Go tool
panics (exit 2) on an `int64` overflow — a latent bug in the original that this port
does not reproduce.

## How it stays small

- No libc, no CRT: own `_start` (via `global_asm!`) + raw `syscall` wrappers.
- No heap: the db is `mmap`'d `PROT_READ`; keys/values are slices into the mapping,
  so `build-std` compiles only `core` (no `alloc`).
- `panic = "immediate-abort"`, `opt-level = "z"`, `lto`, `codegen-units = 1`, strip.

UPX is not applied: at this size the LZMA stub is larger than any gain (`build.sh`
checks and keeps the raw binary).

## Tests

`test-parity.sh` diffs the Rust output against the Go tool byte-for-byte over two
fixtures:

- `../cache.db` — the real (thin) sing-box cache, including the `-r` path.
- `testdata/stress.db` — forces the paths the real db doesn't: B+tree branch pages
  (3000-key bucket), overflow pages (40 KB value), inline + nested buckets, an empty
  bucket, and high-byte key ordering.

Regenerate the stress fixture (from the Go module in `..`):

    cd .. && go run rust/testdata/gen_stress.go rust/testdata/stress.db
