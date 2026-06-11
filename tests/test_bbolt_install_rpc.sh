#!/bin/sh
# tests/test_bbolt_install_rpc.sh
# Drives the rpcd handler's bbolt_status / bbolt_install methods with a local
# file:// "release" (curl handles file://), a stubbed uname, and real sha256sum.
set -e

H=luci-singbox-ui/root/usr/libexec/rpcd/singbox-ui
[ -x "$H" ] || { echo "FAIL: $H not executable"; exit 1; }

if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=$(command -v ucode)
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
else
	echo "SKIP: ucode not available"; exit 0
fi
command -v sha256sum >/dev/null 2>&1 || { echo "SKIP: sha256sum not available"; exit 0; }

TMPDIR=$(mktemp -d); trap 'rm -rf "$TMPDIR"' EXIT
pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

# Stub uname so the arch is deterministic (x86_64) regardless of host.
mkdir -p "$TMPDIR/bin"
cat >"$TMPDIR/bin/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-m" ] && { echo x86_64; exit 0; }
exec /usr/bin/uname "$@"
EOF
chmod +x "$TMPDIR/bin/uname"

# Stub apk: `--print-arch` echoes the contents of $ARCHFILE (host_arch() now
# prefers apk --print-arch over uname -m). Default to the OpenWrt x86_64 pkg
# arch so the install happy-path below stays deterministic.
ARCHFILE="$TMPDIR/apk-arch"; echo "x86_64" >"$ARCHFILE"
cat >"$TMPDIR/bin/apk" <<EOF
#!/bin/sh
[ "\$1" = "--print-arch" ] && { cat "$ARCHFILE"; exit 0; }
exit 0
EOF
chmod +x "$TMPDIR/bin/apk"

# Build a fake "release" dir with the x86_64 asset + a correct sha256sums.txt.
REL="$TMPDIR/release"; mkdir -p "$REL"
printf 'FAKE-BBOLT-CLIENT-BINARY\n' >"$REL/bbolt-client-rs-x86_64"
( cd "$REL" && sha256sum bbolt-client-rs-x86_64 >sha256sums.txt )

# Stub curl: copy $REL/<basename-of-url> to the -o target (avoids depending on a
# real curl with the FILE protocol, which busybox/OpenWrt may not ship).
cat >"$TMPDIR/bin/curl" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o) out="\$2"; shift 2 ;;
		-sfL|-s|-f|-L) shift ;;
		*) url="\$1"; shift ;;
	esac
done
base=\$(basename "\$url")
[ -f "$REL/\$base" ] || exit 22
cp "$REL/\$base" "\$out"
EOF
chmod +x "$TMPDIR/bin/curl"
export PATH="$TMPDIR/bin:$PATH"

TARGET="$TMPDIR/install/bbolt-client"
export SINGBOX_BBOLT_BIN="$TARGET"
export BBOLT_RELEASE_BASE="http://example.invalid/dl"

# shellcheck disable=SC2086
run_h() { "$UCODE_BIN" $UCODE_LIB_FLAGS "$H" "$@"; }

echo "-- bbolt_status before install → installed:false"
out=$(echo '{}' | run_h call bbolt_status)
echo "$out" | grep -q '"installed": *false' || { echo "$out"; fail "expected installed:false"; }
pass "status reports not-installed"

echo "-- bbolt_install happy path → verify + install 0755"
out=$(echo '{}' | run_h call bbolt_install)
echo "$out" | grep -q '"installed": *true' || { echo "$out"; fail "install did not report success"; }
[ -x "$TARGET" ] || fail "binary not installed/executable"
grep -q 'FAKE-BBOLT-CLIENT-BINARY' "$TARGET" || fail "installed binary content wrong"
pass "install verifies sha256 and installs"

echo "-- bbolt_status after install → installed:true"
out=$(echo '{}' | run_h call bbolt_status)
echo "$out" | grep -q '"installed": *true' || { echo "$out"; fail "expected installed:true"; }
pass "status reports installed"

echo "-- sha256 mismatch → refuse to install"
rm -f "$TARGET"
# Corrupt the published checksum.
printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  bbolt-client-rs-x86_64\n' >"$REL/sha256sums.txt"
out=$(echo '{}' | run_h call bbolt_install)
echo "$out" | grep -qi 'sha256 mismatch' || { echo "$out"; fail "expected sha256 mismatch error"; }
[ ! -e "$TARGET" ] || fail "binary must NOT be installed on mismatch"
pass "sha256 mismatch refused"

echo "-- unknown arch → error"
echo "mips64" >"$ARCHFILE"
cat >"$TMPDIR/bin/uname" <<'EOF'
#!/bin/sh
[ "$1" = "-m" ] && { echo mips64; exit 0; }
exec /usr/bin/uname "$@"
EOF
chmod +x "$TMPDIR/bin/uname"
out=$(echo '{}' | run_h call bbolt_install)
echo "$out" | grep -qi 'unsupported arch' || { echo "$out"; fail "expected unsupported arch error"; }
pass "unknown arch rejected"

# host_arch() maps apk --print-arch prefixes to bbolt asset arches. bbolt_status
# exposes the resolved arch side-effect-free ("arch": "<arch>"), so we drive it
# per apk --print-arch value. mipsel MUST resolve before mips (mipsel_* also
# starts with "mips").
echo "-- host_arch prefix map (via apk --print-arch)"
for pair in \
  "x86_64=x86_64" \
  "aarch64_cortex-a53=aarch64" "aarch64_generic=aarch64" \
  "arm_cortex-a7=armv7" "arm_cortex-a15_neon-vfpv4=armv7" \
  "mipsel_24kc=mipsel" "mipsel_74kc=mipsel" \
  "mips_24kc=mips"; do
	pa=${pair%%=*}; want=${pair##*=}
	echo "$pa" >"$ARCHFILE"
	out=$(echo '{}' | run_h call bbolt_status)
	echo "$out" | grep -q "\"arch\": *\"$want\"" || { echo "$out"; fail "host_arch($pa) != $want"; }
done
pass "apk --print-arch prefixes mapped (incl. mipsel before mips)"

echo "-- armeb (big-endian ARM) is unsupported"
echo "armeb_xscale" >"$ARCHFILE"
out=$(echo '{}' | run_h call bbolt_status)
echo "$out" | grep -q '"arch": *""' || { echo "$out"; fail "armeb must be unsupported (empty arch)"; }
pass "armeb rejected"

echo "-- BBOLT_BASE default points at the fixed bbolt-latest tag"
grep -q 'releases/download/bbolt-latest' "$H" || fail "BBOLT_BASE not bbolt-latest"
pass "BBOLT_BASE → bbolt-latest"

echo "OK"
