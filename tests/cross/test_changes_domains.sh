#!/bin/sh
# tests/cross/test_changes_domains.sh
# Exercises the pure path->domain classifier (tests/lib/domain_classify.sh)
# used by tests/run.sh's SB_DOMAIN filter (the CI `changes` job now derives
# domains via dorny/paths-filter — see the static wiring guard below).
# Directory-based 4-domain model:
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

# 8b) the standalone sing-box-extended workflow is EXCLUDED from the .github
#     shared fan-out: changing ONLY it must trigger no domain.
SBX=.github/workflows/sing-box-extended.yml
expect "$SBX" bbolt     false
expect "$SBX" backend   false
expect "$SBX" ui        false
expect "$SBX" packaging false
# but it does NOT mask a real shared github change alongside it.
SBX_PLUS=".github/workflows/sing-box-extended.yml
.github/workflows/build.yml"
expect "$SBX_PLUS" bbolt     true
expect "$SBX_PLUS" backend   true
expect "$SBX_PLUS" ui        true
expect "$SBX_PLUS" packaging true
# realistic combo (this very feed change): the sbx workflow + a packaging file
# => packaging ONLY, not a full fan-out.
SBX_PKG=".github/workflows/sing-box-extended.yml
scripts/build-feed.sh"
expect "$SBX_PKG" packaging true
expect "$SBX_PKG" bbolt     false
expect "$SBX_PKG" backend   false
expect "$SBX_PKG" ui        false

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

# --- static wiring guard: build.yml `changes` job (dorny/paths-filter) ---
# The CI changes job derives domains via dorny/paths-filter (not this classifier);
# domain_classify.sh remains the source of truth for tests/run.sh's SB_DOMAIN
# filter, exercised by the behavioural cases above.
BY=.github/workflows/build.yml
grep -qE 'dorny/paths-filter@' "$BY" || fail "changes job no longer uses dorny/paths-filter"
# Each directory domain is a declared paths-filter AND a job output.
for _d in bbolt backend ui packaging; do
	grep -qE "steps\.agg\.outputs\.${_d}" "$BY" || fail "changes job does not export ${_d} output"
done
# Heavy jobs gate on their domain output (bbolt no longer always-runs).
grep -qE "needs\.changes\.outputs\.bbolt == 'true'"     "$BY" || fail "bbolt job not gated on bbolt domain"
grep -qE "needs\.changes\.outputs\.backend == 'true'"   "$BY" || fail "test job not gated on backend domain"
grep -qE "needs\.changes\.outputs\.ui == 'true'"        "$BY" || fail "ui jobs not gated on ui domain"
grep -qE "needs\.changes\.outputs\.packaging == 'true'" "$BY" || fail "packaging job not gated on packaging domain"
# The standalone sing-box-extended workflow must not fan out to luci domains.
grep -qE 'sing-box-extended\.yml' "$BY" || fail "changes job lost the sing-box-extended carve-out"

# --- goal-e isolation matrix (documented) ---
# | changed path                          | bbolt | backend | ui  | pkg |
# |---------------------------------------|-------|---------|-----|-----|
# | bbolt-client/src/main.rs              | true  | false   | F   | F   |
# | singbox-ui/.../outbound.uc            | false | true    | F   | F   |
# | luci-app-singbox-ui/.../main.js       | false | false   | T   | F   |
# | scripts/build-apk.sh                  | false | false   | F   | T   |
# | tests/lib/sb_helpers.sh (shared)      | true  | true    | T   | T   |
matrix() { # files var1=want1 var2=want2 ...
	_f="$1"; shift
	for kv in "$@"; do
		expect "$_f" "${kv%%=*}" "${kv#*=}"
	done
}
matrix "bbolt-client/src/main.rs"                                            bbolt=true backend=false ui=false packaging=false
matrix "singbox-ui/root/usr/share/singbox-ui/lib/outbound.uc"                bbolt=false backend=true ui=false packaging=false
matrix "luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/main.js" bbolt=false backend=false ui=true packaging=false
matrix "scripts/build-apk.sh"                                                bbolt=false backend=false ui=false packaging=true
matrix "tests/lib/sb_helpers.sh"                                             bbolt=true backend=true ui=true packaging=true

echo "OK"
