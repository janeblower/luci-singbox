#!/bin/sh
# tests/test_build_apk_scripts.sh — verify scripts/build-apk.sh emits the
# explicit init.d enable+start invocations in its package lifecycle scripts.
#
# default_postinst derives the pkgname from `basename "${1%.*}"`, i.e. the
# script's filename minus extension. apk-mkpkg names our script
# "post-install.sh" (not "<pkgname>.postinst"), so default_postinst resolves
# the pkgname as "post-install" and silently fails to enable the init.d
# service. The wrapper must therefore enable/start /etc/init.d/singbox-ui
# explicitly. This test guards that contract.
set -e

S=scripts/build-apk.sh
[ -f "$S" ] || { echo "FAIL: $S missing"; exit 1; }

echo "-- post-install enables and starts singbox-ui"
grep -q '/etc/init.d/singbox-ui enable'  "$S" \
    || { echo "FAIL: post-install must call '/etc/init.d/singbox-ui enable'"; exit 1; }
grep -q '/etc/init.d/singbox-ui start'   "$S" \
    || { echo "FAIL: post-install must call '/etc/init.d/singbox-ui start'"; exit 1; }
echo "  PASS"

echo "-- post-upgrade restarts (not stop+start) for minimal downtime"
grep -q '/etc/init.d/singbox-ui restart' "$S" \
    || { echo "FAIL: post-upgrade must call '/etc/init.d/singbox-ui restart'"; exit 1; }
echo "  PASS"

echo "-- pre-deinstall stops and disables"
grep -q '/etc/init.d/singbox-ui stop'    "$S" \
    || { echo "FAIL: pre-deinstall must call '/etc/init.d/singbox-ui stop'"; exit 1; }
grep -q '/etc/init.d/singbox-ui disable' "$S" \
    || { echo "FAIL: pre-deinstall must call '/etc/init.d/singbox-ui disable'"; exit 1; }
echo "  PASS"

echo "OK"
