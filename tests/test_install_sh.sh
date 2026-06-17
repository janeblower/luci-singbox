#!/bin/sh
# Unit test for the FEED-based install.sh. Drives the new flow WITHOUT network:
# stub `apk` (records args; --print-arch prints the chosen arch; update/add are
# no-ops) and stub the downloader (wget) to write a placeholder key file, both on
# PATH ahead of the real binaries. Root paths (/etc/apk/...) are redirected via
# install.sh's APK_KEYS_DIR / APK_REPO_DIR env hooks into a temp fakeroot.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; mkdir -p "$BIN"
PATH="$BIN:$PATH"
fail() { echo "FAIL: $1" >&2; exit 1; }

PAGES_URL="http://example.test/feed"
KEYS_DIR="$TMP/keys"
REPO_DIR="$TMP/repos"
LIST="$REPO_DIR/luci-singbox.list"

# --- stubs ---
# apk: --print-arch -> chosen arch (reads $ARCHFILE); update -> no-op;
#      add -> record full invocation to $TMP/apk.log
ARCHFILE="$TMP/arch"; echo "x86_64" > "$ARCHFILE"
cat > "$BIN/apk" <<EOF
#!/bin/sh
case "\$1" in
  --print-arch) cat "$ARCHFILE" ;;
  update) : ;;
  add) shift; echo "apk add \$*" >> "$TMP/apk.log" ;;
  *) : ;;
esac
EOF
chmod +x "$BIN/apk"

# wget: record the requested URL, write a placeholder file to -O <out>.
# busybox form: wget -q -O <out> <url>
cat > "$BIN/wget" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do case "\$1" in -O) out="\$2"; shift 2 ;; -q|-nv) shift ;; *) url="\$1"; shift ;; esac; done
echo "\$url" >> "$TMP/wget.log"
[ -n "\$out" ] && echo "PLACEHOLDER-KEY" > "\$out"
exit 0
EOF
chmod +x "$BIN/wget"

# id: pretend root
printf '#!/bin/sh\necho 0\n' > "$BIN/id"; chmod +x "$BIN/id"

run_install() {
  SINGBOX_INSTALL_TEST=1 \
  PAGES_URL="$PAGES_URL" \
  SINGBOX_FEED_MINOR="25.12" \
  APK_KEYS_DIR="$KEYS_DIR" \
  APK_REPO_DIR="$REPO_DIR" \
  sh "$ROOT/install.sh"
}

# --- TEST 1: happy path (x86_64) — key fetched, repo list written, no apk add ---
echo "x86_64" > "$ARCHFILE"
: > "$TMP/wget.log"; : > "$TMP/apk.log"
rm -rf "$KEYS_DIR" "$REPO_DIR"
run_install || fail "install.sh exited nonzero (happy path)"

# (a) signing key was fetched (URL asked + file written into APK_KEYS_DIR)
grep -qx "$PAGES_URL/luci-singbox.pem" "$TMP/wget.log" \
  || fail "wget not asked for $PAGES_URL/luci-singbox.pem; got: $(cat "$TMP/wget.log")"
[ -s "$KEYS_DIR/luci-singbox.pem" ] \
  || fail "signing key not written to APK_KEYS_DIR ($KEYS_DIR/luci-singbox.pem)"

# (b) repo-list line equals <PAGES_URL>/<minor>/x86_64/luci-singbox/packages.adb
[ -f "$LIST" ] || fail "repo list not written to $LIST"
want="$PAGES_URL/25.12/x86_64/luci-singbox/packages.adb"
got=$(cat "$LIST")
[ "$got" = "$want" ] || fail "repo list mismatch: want '$want' got '$got'"

# SINGBOX_INSTALL_TEST=1 must NOT run apk add
[ -s "$TMP/apk.log" ] && fail "apk add ran under SINGBOX_INSTALL_TEST=1"

# --- TEST 2: unsupported arch aborts non-zero, no repo list, no apk add ---
echo "ppc64" > "$ARCHFILE"
: > "$TMP/apk.log"
rm -rf "$KEYS_DIR" "$REPO_DIR"
if out=$(run_install 2>&1); then
  fail "install.sh accepted unsupported arch ppc64 (got: $out)"
fi
echo "$out" | grep -qi "unsupported" \
  || fail "no 'unsupported' message for arch ppc64; got: $out"
[ -f "$LIST" ] && fail "repo list written for unsupported arch ppc64"
[ -s "$TMP/apk.log" ] && fail "apk add ran for unsupported arch ppc64"

# --- TEST 3: minor derivation default (no SINGBOX_FEED_MINOR, no os-release) ---
echo "aarch64_generic" > "$ARCHFILE"
: > "$TMP/wget.log"
rm -rf "$KEYS_DIR" "$REPO_DIR"
SINGBOX_INSTALL_TEST=1 PAGES_URL="$PAGES_URL" \
  APK_KEYS_DIR="$KEYS_DIR" APK_REPO_DIR="$REPO_DIR" \
  sh "$ROOT/install.sh" || fail "install.sh exited nonzero (default-minor path)"
got=$(cat "$LIST")
case "$got" in
  "$PAGES_URL/"*"/aarch64_generic/luci-singbox/packages.adb") : ;;
  *) fail "default-minor repo list malformed: $got" ;;
esac

# --- TEST 4: real apk add target (drop SINGBOX_INSTALL_TEST so apk add runs) ---
echo "x86_64" > "$ARCHFILE"
: > "$TMP/apk.log"
rm -rf "$KEYS_DIR" "$REPO_DIR"
PAGES_URL="$PAGES_URL" SINGBOX_FEED_MINOR="25.12" \
  APK_KEYS_DIR="$KEYS_DIR" APK_REPO_DIR="$REPO_DIR" \
  sh "$ROOT/install.sh" || fail "install.sh exited nonzero (apk add path)"
grep -qx "apk add luci-app-singbox-ui luci-i18n-singbox-ui-ru" "$TMP/apk.log" \
  || fail "apk add target wrong; got: $(cat "$TMP/apk.log")"

echo "ALL CHECKS PASSED (install.sh)"
