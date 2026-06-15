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
# apk: --print-arch -> chosen arch (reads $ARCHFILE); add -> record invocation
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

# --- fixtures served for aarch64_cortex-a53 ---
# serve_fixtures: (re)create the served apks + a matching sha256sums.txt. With
# an argument of "noi18n" the Russian translation package is NOT served (so the
# 404 path can be exercised).
serve_fixtures() {
  rm -f "$TMP/serve/"*.apk "$TMP/serve/sha256sums.txt"
  echo "FAKE_APK_AARCH64_A53" > "$TMP/serve/luci-singbox-ui-aarch64_cortex-a53.apk"
  if [ "${1:-}" != "noi18n" ]; then
    echo "FAKE_I18N_RU" > "$TMP/serve/luci-i18n-singbox-ui-ru.apk"
  fi
  # bare basenames in the second column (matches build.yml's `sha256sum *.apk`,
  # which install.sh's awk expects: $2==name or $2=="*"name).
  ( cd "$TMP/serve" && for f in *.apk; do sha256sum "$f"; done ) > "$TMP/serve/sha256sums.txt"
}
serve_fixtures

# --- TEST 1: happy path — per-arch asset AND the ru i18n package are installed ---
: > "$TMP/apk.log"
echo "aarch64_cortex-a53" > "$ARCHFILE"
SINGBOX_INSTALL_TEST=1 \
APK_BASE="http://x/" \
sh "$ROOT/install.sh" || fail "install.sh exited nonzero (happy path)"

grep -q "luci-singbox-ui-aarch64_cortex-a53.apk" "$TMP/apk.log" \
  || fail "apk add not called with the per-arch asset luci-singbox-ui-aarch64_cortex-a53.apk"
grep -q "luci-i18n-singbox-ui-ru.apk" "$TMP/apk.log" \
  || fail "apk add not called with the ru i18n package luci-i18n-singbox-ui-ru.apk"

# --- TEST 2: apk sha256 mismatch aborts BEFORE apk add ---
echo "TAMPERED_APK" > "$TMP/serve/luci-singbox-ui-aarch64_cortex-a53.apk"
: > "$TMP/apk.log"
if SINGBOX_INSTALL_TEST=1 APK_BASE="http://x/" \
   sh "$ROOT/install.sh" 2>/dev/null; then
  fail "install.sh accepted a tampered apk (apk sha256 not enforced)"
fi
grep -q "luci-singbox-ui-aarch64_cortex-a53.apk" "$TMP/apk.log" 2>/dev/null && \
  fail "apk add ran despite a tampered apk (verified after install, not before)"

# Restore good fixtures for subsequent tests
serve_fixtures

# --- TEST 3: unsupported arch aborts with clear message, apk add not called ---
echo "riscv64_generic" > "$ARCHFILE"
: > "$TMP/apk.log"
out=$(SINGBOX_INSTALL_TEST=1 APK_BASE="http://x/" \
  sh "$ROOT/install.sh" 2>&1 || true)
echo "$out" | grep -qi "unsupported" \
  || fail "no 'unsupported' message for uncovered arch riscv64_generic; got: $out"
grep -q "." "$TMP/apk.log" 2>/dev/null && \
  fail "apk add was called for unsupported arch riscv64_generic"

# --- TEST 4: ru i18n absent from release — main apk still installs, no i18n add ---
serve_fixtures noi18n
echo "aarch64_cortex-a53" > "$ARCHFILE"
: > "$TMP/apk.log"
SINGBOX_INSTALL_TEST=1 APK_BASE="http://x/" \
  sh "$ROOT/install.sh" || fail "install.sh exited nonzero when ru i18n is absent"
grep -q "luci-singbox-ui-aarch64_cortex-a53.apk" "$TMP/apk.log" \
  || fail "main apk not installed when i18n absent"
grep -q "luci-i18n-singbox-ui-ru.apk" "$TMP/apk.log" && \
  fail "i18n apk add attempted despite the package being absent from the release"

# --- TEST 5: tampered i18n apk (sha256 mismatch) aborts before ANY apk add ---
serve_fixtures
echo "TAMPERED_I18N" > "$TMP/serve/luci-i18n-singbox-ui-ru.apk"   # hash no longer matches
echo "aarch64_cortex-a53" > "$ARCHFILE"
: > "$TMP/apk.log"
if SINGBOX_INSTALL_TEST=1 APK_BASE="http://x/" \
   sh "$ROOT/install.sh" 2>/dev/null; then
  fail "install.sh accepted a tampered i18n apk (sha256 not enforced)"
fi
grep -q "." "$TMP/apk.log" 2>/dev/null && \
  fail "apk add ran despite a tampered i18n apk (verify-before-install violated)"

echo "ALL CHECKS PASSED (install.sh)"
