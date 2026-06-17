#!/bin/sh
# tests/test_audit_g8_docs.sh
# Regression guard for audit group G8 (docs / i18n). Pins the documentation
# rewrites to the actual code so the docs cannot silently rot back to the
# superseded C3-era state.
#
#   13.1 — docs/protocol-descriptors.md describes the post-E2 registry-only
#          model: no legacy-switch / SSH narrative; every protocol named in
#          the require-list block exists as a lib/protocols/*.uc file.
#   13.5 — docs/uci-schema.md: vmess no longer appears in the
#          multiplex_enabled depends value (vmess dropped in E2).
#   13.3 — CHANGELOG.md records the luci-app-singbox-ui -> luci-singbox-ui
#          package rename (commit 3aa0ffe).
#   13.4 — README.md carries an English summary section.
#
# POSIX-portable: sh + grep + sed only. Host-runnable (no ucode/VM needed).
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DESC="$ROOT/docs/protocol-descriptors.md"
SCHEMA="$ROOT/docs/uci-schema.md"
CHANGELOG="$ROOT/CHANGELOG.md"
README="$ROOT/README.md"
PROTODIR="$ROOT/${SB_LIB}/builder/protocols"

fail() { echo "FAIL: $1"; exit 1; }

for f in "$DESC" "$SCHEMA" "$CHANGELOG" "$README"; do
  [ -f "$f" ] || fail "$f missing"
done

# ---------------------------------------------------------------------------
# 13.1 — protocol-descriptors.md is the post-E2 registry-only doc
# ---------------------------------------------------------------------------

# Must NOT resurrect the C3-era narrative. These are the specific stale claims
# from the superseded doc (registry-first-then-legacy-fallback dispatch and the
# incremental-migration plan) — not benign mentions like "no … fallback".
grep -qi "consults the registry FIRST"   "$DESC" && fail "13.1: descriptors doc still claims registry-first-then-fallback dispatch"
grep -qi "Otherwise the legacy"          "$DESC" && fail "13.1: descriptors doc still describes a legacy switch fallback"
grep -qi "legacy dispatcher"             "$DESC" && fail "13.1: descriptors doc still references the 'legacy dispatcher'"
grep -qiE "^## Migration plan"           "$DESC" && fail "13.1: descriptors doc still has a 'Migration plan' section"
# SSH was a phantom descriptor; it must not be presented as a shipped example.
grep -qiE "protocols\.ssh|protocols/ssh\.uc|SSH (outbound|descriptor)" "$DESC" \
  && fail "13.1: descriptors doc still references a nonexistent SSH descriptor"

# Must describe the registry-only dispatch and the updated field vocabulary.
grep -qi "registry-only"        "$DESC" || fail "13.1: descriptors doc does not state the registry-only model"
# Each vocabulary keyword must appear as a backtick-opened code span (the hint
# list uses `placeholder: "<text>"`, prose uses `virtual` / `enum`).
for kw in enum dynamic placeholder virtual values; do
  grep -qE "\`${kw}[\`:]" "$DESC" || fail "13.1: field vocabulary missing '$kw'"
done
# combobox vs strict distinction for values.
grep -qi "combobox" "$DESC" || fail "13.1: descriptors doc does not explain values-as-combobox"

# Every protocol module named in a require-list line of the doc must exist as
# a real descriptor file. This is the cheap doc-lint the audit suggested.
proto_mods=$(grep -oE 'protocols\.[a-z0-9_]+' "$DESC" | sed 's/^protocols\.//' | sort -u)
[ -n "$proto_mods" ] || fail "13.1: no protocols.* modules referenced in the doc"
for m in $proto_mods; do
  # registry/_shared are namespaces, not protocol files; skip them.
  case "$m" in registry|_shared) continue ;; esac
  [ -f "$PROTODIR/$m.uc" ] || fail "13.1: doc names protocols.$m but $PROTODIR/$m.uc does not exist"
done
echo "PASS: 13.1 protocol-descriptors.md matches post-E2 registry-only code"

# ---------------------------------------------------------------------------
# 13.5 — vmess dropped from the multiplex_enabled depends value
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # literal backticks in the markdown table, no expansion intended
mux_row=$(grep -E '^\| `multiplex_enabled`' "$SCHEMA") || fail "13.5: multiplex_enabled row missing"
case "$mux_row" in
  *vmess*) fail "13.5: multiplex_enabled depends value still lists vmess" ;;
esac
# sanity: the surviving protocols are still documented.
case "$mux_row" in
  *vless*trojan*shadowsocks*) : ;;
  *) fail "13.5: multiplex_enabled row lost its protocol depends value" ;;
esac
echo "PASS: 13.5 uci-schema.md multiplex_enabled depends drops vmess"

# ---------------------------------------------------------------------------
# 13.3 — CHANGELOG records the rename
# ---------------------------------------------------------------------------
grep -q "luci-app-singbox-ui" "$CHANGELOG" || fail "13.3: CHANGELOG does not mention old package name"
grep -q "luci-singbox-ui"     "$CHANGELOG" || fail "13.3: CHANGELOG does not mention new package name"
grep -q "3aa0ffe"             "$CHANGELOG" || fail "13.3: CHANGELOG does not reference rename commit 3aa0ffe"
echo "PASS: 13.3 CHANGELOG records the package rename"

# ---------------------------------------------------------------------------
# 13.4 — README has an English summary covering the key operator caveats
# ---------------------------------------------------------------------------
grep -qi "## English" "$README" || fail "13.4: README has no English section heading"
grep -qi "apk add"    "$README" || fail "13.4: README English section lacks an install command"
# fw3 conflict warning present in English.
grep -qiE "Conflicts with .firewall|fw3" "$README" || fail "13.4: README English section lacks the fw3 conflict warning"
# tproxy ip-rule prerequisite present in English (the 'ip rule fwmark' note).
grep -qi "ip rule" "$README" || fail "13.4: README does not mention the tproxy ip-rule prerequisite"
echo "PASS: 13.4 README carries an English summary with the key caveats"

echo "PASS: test_audit_g8_docs"
