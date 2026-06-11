#!/bin/sh
# Build the smallest static, libc-free bbolt-client for OpenWrt: x86_64, aarch64,
# armv7, mipsel, and mips. Requires a nightly toolchain with rust-src (pinned in
# rust-toolchain.toml). Cross targets link with the bundled rust-lld (no cross-gcc).
#
# Outputs: ./bbolt-client-rs-{x86_64,aarch64,armv7,mipsel,mips} and ./bbolt-client-rs
# (a copy of the native x86_64 build, used by ./test.sh). Each binary is a fully
# static ELF with no libc dependency, so it runs on glibc and musl/OpenWrt alike.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

# rust-objcopy ships with the toolchain (llvm-tools); override via $OBJCOPY if needed.
OBJCOPY="${OBJCOPY:-rust-objcopy}"

build_one() {
  triple="$1"; arch="$2"
  cargo +nightly build --release --target "$triple"
  cp "target/$triple/release/bbolt-client-rs" "bbolt-client-rs-$arch"
  # MIPS targets emit a huge non-allocated .pdr (procedure-descriptor) section —
  # ~23 KB, not in any LOAD segment, so it's pure file-size dead weight (zero
  # runtime effect). cargo's strip=true does NOT drop .pdr (it isn't flagged as
  # debug), so remove it explicitly. Cuts the mips/mipsel binary ~32 KB → ~8 KB.
  case "$arch" in
    mips|mipsel) "$OBJCOPY" --remove-section .pdr "bbolt-client-rs-$arch" ;;
  esac
  printf '%-8s %6d bytes  %s\n' "$arch" "$(wc -c < "bbolt-client-rs-$arch")" \
    "$(file -b "bbolt-client-rs-$arch" | cut -d, -f1-2)"
}

build_one x86_64-unknown-linux-gnu       x86_64
build_one aarch64-unknown-linux-gnu      aarch64
build_one armv7-unknown-linux-gnueabihf  armv7
build_one mipsel-unknown-linux-musl      mipsel
build_one mips-unknown-linux-musl        mips
cp bbolt-client-rs-x86_64 bbolt-client-rs   # native default for ./test.sh
