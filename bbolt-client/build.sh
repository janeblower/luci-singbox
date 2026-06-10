#!/bin/sh
# Build the smallest static, libc-free bbolt-client for OpenWrt: x86_64 and
# aarch64. Requires a nightly toolchain with rust-src (pinned in
# rust-toolchain.toml). aarch64 links with the bundled rust-lld (no cross-gcc).
#
# Outputs: ./bbolt-client-rs-x86_64, ./bbolt-client-rs-aarch64, and ./bbolt-client-rs
# (a copy of the native x86_64 build, used by ./test.sh). Each binary is a fully
# static ELF with no libc dependency, so it runs on glibc and musl/OpenWrt alike.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

build_one() {
  triple="$1"; arch="$2"
  cargo +nightly build --release --target "$triple"
  cp "target/$triple/release/bbolt-client-rs" "bbolt-client-rs-$arch"
  printf '%-8s %6d bytes  %s\n' "$arch" "$(wc -c < "bbolt-client-rs-$arch")" \
    "$(file -b "bbolt-client-rs-$arch" | cut -d, -f1-2)"
}

build_one x86_64-unknown-linux-gnu  x86_64
build_one aarch64-unknown-linux-gnu aarch64
cp bbolt-client-rs-x86_64 bbolt-client-rs   # native default for ./test.sh
