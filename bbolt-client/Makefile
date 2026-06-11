# bbolt-client-rs — minimal static no-libc bbolt reader (x86_64/aarch64/armv7/mipsel/mips, nightly Rust).
.PHONY: all build test clean

all: build

build:
	./build.sh

# Native (x86_64) regression test vs committed golden snapshots.
# Also test the aarch64 build if qemu-aarch64 is installed:
#   RUN="qemu-aarch64 target/aarch64-unknown-linux-gnu/release/bbolt-client-rs" ./test.sh
test: build
	./test.sh

clean:
	export PATH="$$HOME/.cargo/bin:$$PATH"; cargo +nightly clean 2>/dev/null || true
	rm -f bbolt-client-rs bbolt-client-rs-x86_64 bbolt-client-rs-aarch64 \
	      bbolt-client-rs-armv7 bbolt-client-rs-mipsel bbolt-client-rs-mips
