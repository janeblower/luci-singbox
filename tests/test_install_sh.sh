#!/bin/sh
# Unit test for install.sh: stub the downloader (wget), apk, sha256sum, uname/apk-arch
# via PATH + env overrides so nothing hits the network or the real filesystem.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
PATH="$BIN:$PATH"
fail() { echo "FAIL: $1" >&2; exit 1; }

# --- stubs ---
# apk: --print-arch -> chosen arch; add -> record the invocation
ARCHFILE="$TMP/arch"; echo "aarch64_cortex-a53" > "$ARCHFILE"
cat > "$BIN/apk" <<EOF
#!/bin/sh
case "\$1" in
  --print-arch) cat "$ARCHFILE" ;;
  update) : ;;
  add) echo "apk add \$*" >> "$TMP/apk.log" ;;
esac
EOF
chmod +x "$BIN/apk"

# wget: serve files from $TMP/serve based on the requested URL's basename
mkdir -p "$TMP/serve"
cat > "$BIN/wget" <<EOF
#!/bin/sh
# busybox wget form: wget -O <out> <url>
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -O) out="\$2"; shift 2 ;; -q|-nv) shift ;; *) url="\$1"; shift ;; esac; done
base=\${url##*/}
[ -f "$TMP/serve/\$base" ] || { echo "404 \$base" >&2; exit 1; }
cp "$TMP/serve/\$base" "\$out"
EOF
chmod +x "$BIN/wget"
command -v sha256sum >/dev/null || fail "host needs sha256sum for the test"

# id: pretend root
printf '#!/bin/sh\necho 0\n' > "$BIN/id"; chmod +x "$BIN/id"

# --- fixtures served ---
echo "FAKE_APK" > "$TMP/serve/luci-singbox-ui.apk"
echo "FAKE_AARCH64_BINARY" > "$TMP/serve/bbolt-client-rs-aarch64"
# build a matching sha256sums.txt that the script must verify.
# Generate from inside $TMP/serve so the line's path is the bare basename the
# script's awk matches on. (Only the aarch64 line is needed; the real release
# file carries all five arches but extra lines are harmless here.)
( cd "$TMP/serve" && sha256sum bbolt-client-rs-aarch64 ) > "$TMP/serve/sha256sums.txt"

DEST="$TMP/dest"; mkdir -p "$DEST"

# --- run install.sh in test mode ---
SINGBOX_INSTALL_TEST=1 \
APK_BASE="http://x/" BBOLT_BASE="http://x/" \
BBOLT_DEST="$DEST/bbolt-client" \
sh "$ROOT/install.sh" || fail "install.sh exited nonzero"

# --- assertions ---
grep -q "luci-singbox-ui.apk" "$TMP/apk.log" || fail "apk add not called with the apk"
[ -x "$DEST/bbolt-client" ] || fail "bbolt-client not installed 0755"
[ "$(cat "$DEST/bbolt-client")" = "FAKE_AARCH64_BINARY" ] || fail "wrong bbolt content"

# sha mismatch must abort and NOT install
echo "TAMPERED" > "$TMP/serve/bbolt-client-rs-aarch64"
rm -f "$DEST/bbolt-client"
if SINGBOX_INSTALL_TEST=1 APK_BASE="http://x/" BBOLT_BASE="http://x/" \
   BBOLT_DEST="$DEST/bbolt-client" sh "$ROOT/install.sh" 2>/dev/null; then
  fail "install.sh accepted a tampered binary (sha mismatch not enforced)"
fi
[ ! -e "$DEST/bbolt-client" ] || fail "tampered binary was installed"

echo "ALL CHECKS PASSED (install.sh)"
