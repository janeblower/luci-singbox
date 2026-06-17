#!/bin/sh
# Test for scripts/build-feed.sh against a REAL apk-tools 3 (the OpenWrt VM has
# it; a host with the SDK apk also works). A previous stub-based version of this
# test passed while the feed was actually broken on-device: apk reconstructs each
# package URL as "<name>-<version>.apk" and the feed served release-asset names
# -> 404 on download. So this test now builds real tiny apks, runs the feed
# builder, and asserts that every package the generated index references actually
# exists on disk under apk's naming convention.
#
# Four-package split: the per-arch package is bbolt-client-<arch>.apk; the noarch
# trio (singbox-ui / luci-app-singbox-ui / luci-i18n-singbox-ui-ru) is duplicated
# into every arch dir, so each arch dir holds FOUR <name>-<version>.apk files.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
fail() { echo "FAIL: $1" >&2; exit 1; }

# Locate a real apk-tools 3: packaging-domain container / CI provides apk-tools
# 3.0.5+ on PATH; a host with the SDK apk also works; SINGBOX_APK_BIN overrides.
APK="${SINGBOX_APK_BIN:-}"
[ -z "$APK" ] && APK="$(command -v apk 2>/dev/null || true)"
[ -z "$APK" ] && [ -x "$ROOT/.build/sdk/staging_dir/host/bin/apk" ] && APK="$ROOT/.build/sdk/staging_dir/host/bin/apk"

# Hard-fail (not SKIP) on a missing capability: the packaging domain MUST run in
# an environment with a capable apk so the feed contract is really exercised. A
# silent SKIP previously let an on-device-broken feed pass CI. The only escape is
# SINGBOX_FEED_TEST_ALLOW_SKIP=1, reserved for environments that genuinely cannot
# supply apk-tools 3.0.5+ (set explicitly, never the default).
skip_or_fail() {
  if [ "${SINGBOX_FEED_TEST_ALLOW_SKIP:-0}" = "1" ]; then
    echo "SKIP test_build_feed: $1 (SINGBOX_FEED_TEST_ALLOW_SKIP=1)"
    exit 0
  fi
  fail "missing capability: $1 (need apk-tools 3.0.5+; set SINGBOX_FEED_TEST_ALLOW_SKIP=1 only if truly unavailable)"
}

[ -n "$APK" ] || skip_or_fail "no apk binary on PATH or SDK build"
"$APK" --version 2>/dev/null | grep -q "apk-tools 3" || skip_or_fail "apk-tools 3 not found ($("$APK" --version 2>/dev/null | head -1))"
"$APK" mkpkg --help 2>&1 | grep -q -- '--info' || skip_or_fail "apk mkpkg lacks --info (apk-tools build too old)"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build the four-package split as real apks. bbolt-client-<arch>.apk is the only
# per-arch one (arch in the filename); the noarch trio carries real metadata.
mkdir -p "$TMP/dist"

# Per-arch: build a bbolt-client-<arch>.apk fixture for ALL 20 covered arches
# (the same set scripts/build-apk.sh's bbolt_arches_* and install.sh's COVERED
# enumerate). build-feed.sh derives the arch dirs from these filenames, so the
# feed must emit one arch dir per fixture and resolve all four packages in each.
COVERED_ARCHES="x86_64 \
aarch64_cortex-a53 aarch64_cortex-a72 aarch64_cortex-a76 aarch64_generic \
arm_cortex-a5_vfpv4 arm_cortex-a7 arm_cortex-a7_neon-vfpv4 arm_cortex-a7_vfpv4 \
arm_cortex-a8_vfpv3 arm_cortex-a9 arm_cortex-a9_neon arm_cortex-a9_vfpv3-d16 \
arm_cortex-a15_neon-vfpv4 \
mipsel_24kc mipsel_24kc_24kf mipsel_74kc mipsel_mips32 \
mips_24kc mips_mips32"
mkdir -p "$TMP/b/x"; echo a > "$TMP/b/x/a"
for arch in $COVERED_ARCHES; do
  ( cd "$TMP/b" && "$APK" mkpkg \
      --info name:bbolt-client --info version:9.9.9-r1 --info arch:"$arch" \
      --info description:t --info license:GPL-2.0-or-later \
      --files x -o "$TMP/dist/bbolt-client-$arch.apk" >/dev/null )
done

# Noarch core.
mkdir -p "$TMP/c/x"; echo b > "$TMP/c/x/b"
( cd "$TMP/c" && "$APK" mkpkg \
    --info name:singbox-ui --info version:9.9.9-r1 --info arch:all \
    --info description:t --info license:GPL-2.0-or-later \
    --files x -o "$TMP/dist/singbox-ui.apk" >/dev/null )

# Noarch LuCI app.
mkdir -p "$TMP/a/x"; echo c > "$TMP/a/x/c"
( cd "$TMP/a" && "$APK" mkpkg \
    --info name:luci-app-singbox-ui --info version:9.9.9-r1 --info arch:all \
    --info description:t --info license:GPL-2.0-or-later \
    --files x -o "$TMP/dist/luci-app-singbox-ui.apk" >/dev/null )

# Noarch i18n.
mkdir -p "$TMP/i/x"; echo d > "$TMP/i/x/d"
( cd "$TMP/i" && "$APK" mkpkg \
    --info name:luci-i18n-singbox-ui-ru --info version:9.9.9-r1 --info arch:all \
    --info description:t --info license:GPL-2.0-or-later \
    --files x -o "$TMP/dist/luci-i18n-singbox-ui-ru.apk" >/dev/null )
echo "DUMMY PUBLIC KEY" > "$TMP/pub.pem"

# No FEED_SIGN_KEY -> unsigned index (signing needs a key + is covered live);
# this test targets the filename/layout contract apk depends on.
FEED_PUBKEY="$TMP/pub.pem" \
PAGES_URL="https://example.test/luci-singbox" \
RELEASE_REPO="acme/luci-singbox" \
APK_BIN="$APK" \
  sh "$ROOT/scripts/build-feed.sh" 25.12 "$TMP/dist" "$TMP/out"

# REGRESSION GUARD (FEED-1): build-feed.sh feed_pkg_filename must anchor on the
# TOP-LEVEL `  name: `/`  version: ` fields (2-space indent) and take the FIRST
# match, so a nested name:/version: in a recursive adbdump can't hijack the
# reconstructed download filename (a wrong name -> 404 on the device). adbdump of
# a normal package emits no nested name:/version:, so feed against a crafted dump
# fixture (a decoy nested pair, deeper-indented, AFTER the real fields) and assert
# the SAME awk program build-feed uses still yields the top-level name-version.
# Arch-independent — run ONCE before the per-arch loop.
# shellcheck disable=SC2016  # awk program — $2 is awk's field, not a shell var
PARSER='
    /^  name: /    && n=="" { n=$2 }
    /^  version: / && v=="" { v=$2 }
    n!="" && v!=""          { printf "%s-%s.apk\n", n, v; exit }
    END { if (n=="" || v=="") exit 1 }'
# Verify the literal program text in build-feed.sh matches what we test (so this
# guard can't pass against a regressed/diverged parser).
# shellcheck disable=SC2016  # matching the literal awk text, not expanding $2
grep -q '/^  name: /    && n=="" { n=\$2 }' "$ROOT/scripts/build-feed.sh" \
  || fail "FEED-1: build-feed.sh feed_pkg_filename no longer anchors on top-level '  name: '"
cat > "$TMP/dump" <<'DUMP'
  name: bbolt-client
  version: 9.9.9-r1
  arch: x86_64
  scripts:
    triggers:
      name: should-be-ignored
      version: 0.0.0-r0
DUMP
got="$(awk "$PARSER" "$TMP/dump")" || fail "FEED-1: parser exited nonzero on a valid dump"
[ "$got" = "bbolt-client-9.9.9-r1.apk" ] \
  || fail "FEED-1: nested name:/version: hijacked the filename; got '$got'"

# Per-arch contract: EVERY covered arch dir holds the four-package stack named
# <name>-<version>.apk, a signed/unsigned packages.adb, and the index resolves
# every referenced package to an on-disk file under apk's naming convention.
for arch in $COVERED_ARCHES; do
  d="$TMP/out/25.12/$arch/luci-singbox"
  [ -d "$d" ] || fail "missing arch dir for $arch"

  [ -f "$d/bbolt-client-9.9.9-r1.apk" ]        || fail "$arch: bbolt-client pkg not named <name>-<version>.apk"
  [ -f "$d/singbox-ui-9.9.9-r1.apk" ]          || fail "$arch: core pkg not named <name>-<version>.apk"
  [ -f "$d/luci-app-singbox-ui-9.9.9-r1.apk" ] || fail "$arch: app pkg not named <name>-<version>.apk"
  [ -f "$d/luci-i18n-singbox-ui-ru-9.9.9-r1.apk" ] || fail "$arch: i18n pkg not named <name>-<version>.apk"
  [ -f "$d/bbolt-client-$arch.apk" ]           && fail "$arch: release-asset name was not renamed"
  [ -f "$d/packages.adb" ]                     || fail "$arch: packages.adb missing"

  napk=$(find "$d" -maxdepth 1 -name '*.apk' | wc -l)
  [ "$napk" -eq 4 ] || fail "$arch: arch dir must hold FOUR apks, found $napk"

  "$APK" adbdump "$d/packages.adb" 2>/dev/null | awk '
    /name:/    {n=$NF}
    /version:/ {v=$NF; print n"-"v".apk"}' | sort -u > "$TMP/want"
  [ -s "$TMP/want" ] || fail "$arch: index has no packages"
  while read -r want; do
    [ -f "$d/$want" ] || fail "$arch: index references missing file: $want"
  done < "$TMP/want"
done

# Exactly 20 arch dirs were produced (no stray, none missing).
ndirs=$(find "$TMP/out/25.12" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$ndirs" -eq 20 ] || fail "expected 20 arch dirs, found $ndirs"

# Public key published at feed root.
[ -f "$TMP/out/luci-singbox.pem" ] || fail "public key not published at feed root"

# The feed is published to the gh-pages branch and Jekyll-built by GitHub Pages
# with jekyll-theme-midnight, so build-feed emits Jekyll sources, NOT HTML.
[ -f "$TMP/out/_config.yml" ] || fail "_config.yml (Jekyll site config) missing"
grep -q "jekyll-theme-midnight" "$TMP/out/_config.yml" || fail "midnight theme not configured"
[ -f "$TMP/out/index.html" ] && fail "build-feed must not emit index.html (Jekyll renders .md)"

# Root landing (index.md) rendered with substitutions, install snippet, no junk.
[ -f "$TMP/out/index.md" ] || fail "landing index.md missing"
grep -q "example.test/luci-singbox" "$TMP/out/index.md" || fail "PAGES_URL not substituted"
grep -q "apk add luci-app-singbox-ui" "$TMP/out/index.md" || fail "install snippet missing"
# The split-era install target is luci-app-singbox-ui (deps pull the rest); the
# old per-arch asset name must not leak into the landing page.
grep -q "luci-singbox-ui-" "$TMP/out/index.md" && fail "stale luci-singbox-ui- asset name in landing"
grep -q "packages.adb" "$TMP/out/index.md" || fail "repo URL must point at packages.adb"
grep -q "github.com/acme/luci-singbox" "$TMP/out/index.md" || fail "RELEASE_REPO not substituted"
# No unsubstituted placeholders left.
grep -q "{{" "$TMP/out/index.md" && fail "unsubstituted {{...}} placeholder in landing"
# Removed for good: the legacy .ipk note and the latest-release download block.
grep -qi "ipk" "$TMP/out/index.md" && fail ".ipk mention must be gone (we have no .ipk)"
grep -q "releases/download/latest" "$TMP/out/index.md" && fail "latest-release block must be gone"

# Browsable Jekyll indexes at version + arch levels (index.md with front matter).
[ -f "$TMP/out/25.12/index.md" ] || fail "version-level index.md missing"
[ -f "$TMP/out/25.12/x86_64/index.md" ] || fail "arch-level index.md missing"
grep -q "layout: default" "$TMP/out/25.12/index.md" || fail "browse page lacks Jekyll front matter"

# Arch list derived from filenames: a never-built arch must not appear.
[ -d "$TMP/out/25.12/riscv64" ] && fail "unexpected arch dir (not in fixture dist)"

echo "PASS test_build_feed"
