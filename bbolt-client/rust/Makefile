# bbolt-client-rs — minimal static no-libc bbolt reader (x86_64, nightly Rust).
.PHONY: all build test clean

all: build

build:
	./build.sh

# Needs the Go oracle built once: (cd .. && CGO_ENABLED=0 go build -o bbolt-client .)
test: build
	./test-parity.sh

clean:
	export PATH="$$HOME/.cargo/bin:$$PATH"; cargo +nightly clean 2>/dev/null || true
	rm -f bbolt-client-rs
