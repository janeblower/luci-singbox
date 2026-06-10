# bbolt-client

A `#![no_std]`, **no-libc**, raw-syscall, read-only [bbolt](https://github.com/etcd-io/bbolt)
reader for sing-box caches (`experimental.cache_file`, e.g. `/etc/sing-box/cache.db`
or `/tmp/singbox-ui-cache.db`), built for minimal size.

Fully static, libc-free binaries: **~7.6 KB** (x86_64) / **~6.2 KB** (aarch64). Each
links no libc and makes raw Linux syscalls, so the single static ELF runs on glibc
hosts and musl/OpenWrt alike.

## Build (nightly required)

    ./build.sh        # -> ./bbolt-client-rs-{x86_64,aarch64}  (+ ./bbolt-client-rs = native)
    make test         # build + self-contained golden regression tests

Needs a nightly toolchain with `rust-src` (pinned in `rust-toolchain.toml`). The build
uses `-Z build-std=core` with `panic = "immediate-abort"` and links with `-nostdlib`
so no libc or CRT is pulled in; the result is a static ELF with no `PT_INTERP`.
**aarch64** cross-links with the toolchain's bundled `rust-lld` — no cross-gcc needed.

CI builds both architectures and runs the tests (aarch64 under `qemu-user`) on every
push — see [`.github/workflows/bbolt-client.yml`](../.github/workflows/bbolt-client.yml).
Binaries are uploaded as artifacts (binary only; no apk packaging yet).

**Supported arches: x86_64 and aarch64 Linux.** The syscall layer is arch-gated
(`#[cfg(target_arch)]`: syscall numbers + the `syscall`/`svc` instruction + `_start`);
everything else is arch-independent. Other arches would need another `nr`/`syscall6`/
`_start` variant.

## Usage

    bbolt-client-rs <db>                   # list buckets
    bbolt-client-rs <db> <bucket>          # list keys in bucket
    bbolt-client-rs <db> <bucket> <key>    # raw value bytes to stdout
    bbolt-client-rs -r <db> <bucket> <key> # strip SavedRuleSet envelope -> .srs

Example — extract a cached rule-set and decompile it:

    bbolt-client-rs -r cache.db rule_set warp-telegram-community-ruleset > rs.srs
    sing-box rule-set decompile rs.srs --output rs.json

Opens read-only with a shared lock and ~1s timeout: if sing-box holds the file
(exclusive lock) it prints `timeout` (exit 1) instead of hanging — copy the db and
read the copy. Exit codes: `0` ok, `1` error (missing file/bucket/key, lock), `2`
bad args. Value output has no trailing newline.

> The OS-error text for a missing file / lock / mmap failure is simplified (a full
> errno→string table is not worth the bytes). The bucket/key/value/`-r`/usage/
> `no bucket`/`no key`/`timeout` outputs are exact.

### SavedRuleSet envelope (`-r`)

The `rule_set` bucket stores a sing-box `experimental/cachefile` envelope, not a raw
`.srs`: `u8 version(==1)`, uvarint content length, the `.srs` content, then trailing
metadata (`LastUpdated`, `LastEtag`). `-r` validates the version + length and emits
only the content. If the envelope format changes upstream, update `unwrap_ruleset`.

### Robustness on corrupt input

A malformed or truncated db is reported as `invalid database` (exit 1) — never a
crash. The parser bounds-checks page spans, rejects page ids that overflow or fail
bbolt's self-identity check (`FastCheck`), and depth-limits the B+tree descent, so a
truncated copy or a crafted db (cyclic page links, a wrapping `pgid`, a bogus
`overflow` field) yields a clean exit instead of a SIGSEGV/SIGILL or a wrong answer.

## How it stays small

- No libc, no CRT: own `_start` (via `global_asm!`) + raw `syscall`/`svc` wrappers.
- No heap: the db is `mmap`'d `PROT_READ`; keys/values are slices into the mapping,
  so `build-std` compiles only `core` (no `alloc`).
- `panic = "immediate-abort"`, `opt-level = "z"`, `lto`, `codegen-units = 1`, strip.

## Tests

`./test.sh` is self-contained — it reduces the binary's output to a sha256 and
compares against committed golden hashes in `testdata/golden/` (originally captured
from the upstream Go `bbolt` reference and frozen). Fixtures in `testdata/`:

- `cache.db` — a real (thin) sing-box cache, including the `-r` path.
- `stress.db` — forces what the real db doesn't: B+tree branch pages, overflow pages
  (a 40 KB value), inline + nested + empty buckets, and high-byte key ordering.
- `cyclic.db` / `wrap.db` / `overflow.db` — crafted corruption for the safety guards.

Run the aarch64 build through the same suite with qemu:

    RUN="qemu-aarch64 target/aarch64-unknown-linux-gnu/release/bbolt-client-rs" ./test.sh

Fixtures are reproducible via the (build-ignored) generators in `testdata/`:
`gen_stress.go` (needs a Go module with `go.etcd.io/bbolt`) and `gen_corrupt.go`
(stdlib only: `go run testdata/gen_corrupt.go <cyclic|wrap|overflow> <out.db>`). After
changing a fixture, refresh golden: `./test.sh gen`.
