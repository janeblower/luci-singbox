#!/bin/sh
# Build the smallest static, libc-free bbolt-client (x86_64). Requires a nightly
# toolchain with rust-src (pinned in rust-toolchain.toml). Output: ./bbolt-client-rs
#
# The binary links NO libc and makes raw syscalls, so the single static ELF runs
# on both glibc hosts and musl/OpenWrt x86_64. x86_64 only.
set -eu
cd "$(dirname "$0")"
export PATH="$HOME/.cargo/bin:$PATH"

cargo +nightly build --release
SRC=target/x86_64-unknown-linux-gnu/release/bbolt-client-rs
cp "$SRC" bbolt-client-rs
RAW=$(wc -c < bbolt-client-rs)
echo "raw:  $RAW bytes"

# UPX only if it actually shrinks the binary (at this size the LZMA stub usually
# does not, and can break some loaders) — keep whichever is smaller.
if command -v upx >/dev/null 2>&1; then
  cp bbolt-client-rs .upx-test
  if upx --best --lzma .upx-test >/dev/null 2>&1; then
    UPXS=$(wc -c < .upx-test)
    if [ "$UPXS" -lt "$RAW" ]; then
      mv .upx-test bbolt-client-rs
      echo "upx:  $UPXS bytes (kept; raw was $RAW)"
    else
      rm -f .upx-test
      echo "upx:  $UPXS bytes >= raw $RAW; kept raw"
    fi
  else
    rm -f .upx-test
    echo "upx:  compression failed; kept raw"
  fi
fi
ls -l bbolt-client-rs
