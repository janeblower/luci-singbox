#!/bin/sh
# tests/cross/test_changes_domains.sh
# Exercises the pure path->domain classifier (tests/lib/domain_classify.sh)
# used by build.yml's `changes` job. Directory-based 4-domain model:
#   bbolt / backend / ui / packaging, plus a shared fan-out that sets all four.
# This is a HOST test (pure sh + grep) — no ucode/node/docker needed.
set -eu
cd "$(dirname "$0")/../.."
. tests/lib/domain_classify.sh
fail() { echo "FAIL: $1" >&2; exit 1; }

# Helper: run the classifier on a literal file list and assert one var.
expect() {
	_files="$1"; _var="$2"; _want="$3"
	_got=$(printf '%s\n' "$_files" | sb_classify_domains | grep "^${_var}=" | cut -d= -f2)
	[ "$_got" = "$_want" ] || fail "files=[$_files] expected $_var=$_want got $_var=$_got"
}

# 1) bbolt-only change => ONLY bbolt true (the goal-e isolation invariant).
expect "bbolt-client/src/main.rs" bbolt     true
expect "bbolt-client/src/main.rs" backend   false
expect "bbolt-client/src/main.rs" ui        false
expect "bbolt-client/src/main.rs" packaging false

# 2) backend ucode change => only backend.
expect "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc" backend   true
expect "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc" bbolt     false
expect "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc" ui        false
expect "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc" packaging false

# 3) parity fixture => backend (parity belongs to the backend builder).
expect "tests/parity/corpus.uc" backend true
expect "tests/parity/corpus.uc" ui      false

# 4) tests/backend/* => backend.
expect "tests/backend/test_outbound_uc.sh" backend true
expect "tests/backend/test_outbound_uc.sh" bbolt   false

# 5) UI source => only ui.
expect "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js" ui        true
expect "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js" backend   false
expect "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js" packaging false

# 6) tests/ui and tests/browser => ui.
expect "tests/ui/test_validators_js.sh"  ui true
expect "tests/browser/01-outbounds.mjs"  ui true

# 7) packaging: scripts, install.sh, feed, any Makefile, tests/cross.
expect "scripts/build-apk.sh"          packaging true
expect "install.sh"                    packaging true
expect "feed/luci-singbox.pem"         packaging true
expect "singbox-ui/Makefile"           packaging true
expect "luci-app-singbox-ui/Makefile"  packaging true
expect "tests/cross/test_build_feed.sh" packaging true
expect "scripts/build-apk.sh"          backend   false

# 8) shared fan-out: tests/lib, tests/run*, tests/docker, tests/browser-container,
#    .github => ALL FOUR true.
for f in "tests/lib/sb_helpers.sh" "tests/run.sh" "tests/run-vm.sh" \
         "tests/docker/Dockerfile" "tests/browser-container/Dockerfile" \
         ".github/workflows/build.yml"; do
	expect "$f" bbolt     true
	expect "$f" backend   true
	expect "$f" ui        true
	expect "$f" packaging true
done

# 9) multi-file change unions domains: a bbolt file + a ui file => both true,
#    backend/packaging false.
MULTI="bbolt-client/build.sh
luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/dns.js"
expect "$MULTI" bbolt     true
expect "$MULTI" ui        true
expect "$MULTI" backend   false
expect "$MULTI" packaging false

# 10) empty input => everything false (no changed files).
expect "" bbolt     false
expect "" backend   false
expect "" ui        false
expect "" packaging false

# --- static wiring guard: build.yml must consume each domain output ---
BY=.github/workflows/build.yml
grep -qE 'echo "bbolt=' "$BY"     || fail "build.yml changes job does not emit bbolt output"
grep -qE 'echo "backend=' "$BY"   || fail "build.yml changes job does not emit backend output"
grep -qE 'echo "ui=' "$BY"        || fail "build.yml changes job does not emit ui output"
grep -qE 'echo "packaging=' "$BY" || fail "build.yml changes job does not emit packaging output"
# Heavy jobs gate on their domain output (bbolt no longer always-runs).
grep -qE "needs\.changes\.outputs\.bbolt == 'true'"     "$BY" || fail "bbolt job not gated on bbolt domain"
grep -qE "needs\.changes\.outputs\.backend == 'true'"   "$BY" || fail "test job not gated on backend domain"
grep -qE "needs\.changes\.outputs\.ui == 'true'"        "$BY" || fail "ui jobs not gated on ui domain"
# changes job sources the shared classifier (single source of truth).
grep -qE 'tests/lib/domain_classify\.sh' "$BY" || fail "changes job does not source domain_classify.sh"
# push gating uses the before-SHA (not only PR base).
grep -qE 'github\.event\.before' "$BY" || fail "changes job does not diff against the push before-SHA"

echo "OK"
