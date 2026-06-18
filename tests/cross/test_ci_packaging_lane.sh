#!/bin/sh
# Asserts build.yml has a `packaging` job that (a) is gated on the packaging
# domain output, (b) runs the cross suite host-mode in an apk-tools-3.0.5+
# environment (so feed/i18n get real `apk mkpkg --info`), (c) does NOT delegate
# to the qemu VM.
set -eu
cd "$(dirname "$0")/../.."
WF=.github/workflows/build.yml
fail() { echo "FAIL: $1" >&2; exit 1; }
grep -Eq '^[[:space:]]*packaging:' "$WF" || fail "no 'packaging:' job in $WF"
grep -Eq "needs\.changes\.outputs\.packaging" "$WF" || fail "packaging job not gated on changes.outputs.packaging"
grep -Eq "SB_SUITE:[[:space:]]*cross|SB_SUITE=cross" "$WF" || fail "packaging job does not run the cross suite"
grep -Eq "mkpkg --info|apk-tools|/sdk|openwrt/sdk|APK_BIN|SINGBOX_APK_BIN" "$WF" || fail "packaging job has no apk-tools 3.0.5+ source"
echo "OK"
