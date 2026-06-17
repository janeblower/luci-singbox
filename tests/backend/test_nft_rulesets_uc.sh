#!/bin/sh
# tests/test_nft_rulesets_uc.sh
# Drives nft-rulesets.uc local-source path validation with a fixture UCI dir + a fake sing-box. No network.
set -e
. "$(dirname "$0")/../lib/sb_helpers.sh"

# Mirror test_generate.sh: skip if ucode/uci-mod unavailable on dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/${SB_LIB}}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SUB_UC=${SB_SHARE}/nft-rulesets.uc
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Sandboxed tmp dir for the script's outputs.
export SINGBOX_TMPDIR="$TMPDIR/runtime"
mkdir -p "$SINGBOX_TMPDIR"

# Every migrated case exercises the LOCAL-source cp path (rs_type=local, .json
# source → detect_rs_format="source" → cp, never `sing-box rule-set decompile`).
# No fixture invokes sing-box, so no stub is needed here.

pass() { echo "  PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

run_uc() {
	# shellcheck disable=SC2086
	UCI_CONFIG_DIR="$TMPDIR" "$UCODE_BIN" $UCODE_LIB_FLAGS "$SUB_UC" "$@"
}

# ---- fetch: local source copy ----
echo "-- fetch copies local .json source to rs_<name>.json"
mkdir -p "$TMPDIR/src"
printf '%s' '{"version":1,"rules":[]}' >"$TMPDIR/src/r.json"
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rA'
	option type 'local'
	option path '$TMPDIR/src/r.json'
	option nft_rules '1'
EOF
run_uc fetch
[ -s "$SINGBOX_TMPDIR/rs_rA.json" ] || fail "rs_rA.json missing"
grep -q '"rules"' "$SINGBOX_TMPDIR/rs_rA.json" || fail "rs_rA.json content wrong"
pass "local source ruleset"

# ---- C2.1.8: local ruleset path must be under a known prefix ----
# Hostile (or accidental) UCI value path=/etc/shadow must NOT be copied into
# the work dir. Only an LuCI admin can write UCI today, but defense in depth.
echo "-- C2.1.8: local ruleset path outside whitelist is rejected"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config ruleset 'rs1'
	option type 'local'
	option path '/root/secret.json'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rs1.json" "$SINGBOX_TMPDIR/rs_rs1.raw"
out=$(run_uc fetch 2>&1 || true)
echo "$out" | grep -qiE 'outside whitelist|invalid path|reject' \
	|| { echo "$out"; fail "expected rejection log, got: $out"; }
if [ -f "$SINGBOX_TMPDIR/rs_rs1.json" ] || [ -f "$SINGBOX_TMPDIR/rs_rs1.raw" ]; then
	fail "rs_rs1 file should not have been created from disallowed path"
fi
pass "local ruleset path outside whitelist is rejected"

echo "-- C2.1.8: local ruleset under /tmp is still accepted"
mkdir -p "$TMPDIR/src"
printf '%s' '{"version":1,"rules":[]}' >"$TMPDIR/src/ok.json"
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rs2'
	option type 'local'
	option path '$TMPDIR/src/ok.json'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rs2.json"
# $TMPDIR resolves under /tmp on standard hosts; skip if not.
case "$TMPDIR" in
	/tmp/*|/var/*|/etc/*|/usr/share/*)
		run_uc fetch >/dev/null 2>&1 || true
		[ -s "$SINGBOX_TMPDIR/rs_rs2.json" ] \
			|| fail "whitelisted local ruleset should have been copied"
		pass "whitelisted local ruleset is accepted"
		;;
	*)
		echo "  SKIP: TMPDIR $TMPDIR not under a whitelist prefix"
		;;
esac

# ---- C2.1.16: local-ruleset cp failure cleans up raw_path ----
# Structural check: the local-ruleset error branch must unlink raw_path so a
# partial copy can't poison subsequent runs. SEC-9 routes this through the
# never-throw unlink_quiet() helper (so one unlink failure can't abort the rest
# of the refresh loop); accept either the bare or the wrapped form.
echo "-- C2.1.16: local-ruleset cp-failure branch removes raw_path"
grep -qE '(fs\.unlink|unlink_quiet)\(raw_path\)' \
	"${SB_SHARE}/nft-rulesets.uc" \
	|| fail "nft-rulesets.uc: missing raw_path cleanup in local branch"
pass "nft-rulesets.uc: local cp-failure cleans up raw_path"

# ---- SEC-9: in-loop unlinks go through the never-throw unlink_quiet helper ----
# A bare fs.unlink that throws inside the per-job loop would abort processing of
# every REMAINING rule-set in the refresh cycle. Assert the helper exists and
# that no bare fs.unlink(m.raw_path) survives in the decompile loop.
echo "-- SEC-9: in-loop unlinks routed through unlink_quiet"
grep -qE 'function unlink_quiet' \
	"${SB_SHARE}/nft-rulesets.uc" \
	|| fail "nft-rulesets.uc: unlink_quiet helper missing (SEC-9)"
grep -qE 'fs\.unlink\(m\.raw_path\)' \
	"${SB_SHARE}/nft-rulesets.uc" \
	&& fail "nft-rulesets.uc: bare fs.unlink(m.raw_path) survives in the loop (SEC-9)" || true
pass "nft-rulesets.uc: in-loop unlinks are exception-safe"

# ---- S3-3: symlink whose target escapes the whitelist is rejected ----
# The symlink path itself is under /tmp (whitelisted), but its target resolves
# to /proc/version, under no whitelist prefix. cp would follow it; the handler
# resolves the link via resolve_local_source (lstat exposes no target field, so
# it walks readlink hop-by-hop) and re-checks the prefix guard at the final
# real path, which must reject it (SEC-8).
echo "-- S3-3: local ruleset symlink escaping whitelist is rejected"
mkdir -p "$TMPDIR/src"
ln -sf /proc/version "$TMPDIR/src/sneaky.json"
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rsLink'
	option type 'local'
	option path '$TMPDIR/src/sneaky.json'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rsLink.json" "$SINGBOX_TMPDIR/rs_rsLink.raw"
out=$(run_uc fetch 2>&1 || true)
echo "$out" | grep -qiE 'outside whitelist|symlink|resolved|unresolvable' \
	|| { echo "$out"; fail "S3-3: expected rejection log for escaping symlink"; }
if [ -f "$SINGBOX_TMPDIR/rs_rsLink.json" ] || [ -f "$SINGBOX_TMPDIR/rs_rsLink.raw" ]; then
	fail "S3-3: escaping symlink should not have produced a file"
fi
pass "S3-3: symlink escaping whitelist is rejected"

# Allow-case: a symlink under the whitelist pointing to an in-whitelist regular
# file must NOT be rejected (proves the readlink re-check ALLOWS legit targets —
# i.e. the guard isn't a blanket reject-all-symlinks). We assert the symlink
# rejection log is absent for this ruleset; the source is a valid local file so
# it proceeds past the symlink guard to the normal cp/decompile path.
echo "-- S3-3: in-whitelist symlink target is allowed (recheck, not reject-all)"
printf '{"version":1,"rules":[]}\n' > "$TMPDIR/src/real_ok.json"
ln -sf "$TMPDIR/src/real_ok.json" "$TMPDIR/src/link_ok.json"
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rsOk'
	option type 'local'
	option path '$TMPDIR/src/link_ok.json'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rsOk.json"
out=$(run_uc fetch 2>&1 || true)
if echo "$out" | grep -qiE "rsOk.*(outside whitelist|unresolvable|relative)"; then
	echo "$out"; fail "S3-3: in-whitelist symlink was wrongly rejected (reject-all regression)"
fi
# Positive proof: the copy actually happened (absence of a reject log alone
# would pass even if nothing was produced).
[ -s "$SINGBOX_TMPDIR/rs_rsOk.json" ] \
	|| fail "S3-3: in-whitelist symlink: expected rs_rsOk.json to be produced"
pass "S3-3: in-whitelist symlink target is allowed"

# ---- SEC-8: MULTI-HOP symlink chain escaping the whitelist is rejected ----
# The OLD guard readlink'd only ONE hop: link -> hop2 (both under /tmp) passed
# its single-hop check even though hop2 itself pointed OUTSIDE the whitelist.
# resolve_local_source must follow the WHOLE chain. Build chain1 -> chain2
# (whitelisted hop) -> /proc/version (outside). The single-hop guard would have
# accepted chain1 (its target chain2 is under /tmp); the chain-walker rejects it.
echo "-- SEC-8: multi-hop symlink chain escaping the whitelist is rejected"
ln -sf /proc/version "$TMPDIR/src/chain2.json"            # hop2 -> outside whitelist
ln -sf "$TMPDIR/src/chain2.json" "$TMPDIR/src/chain1.json" # hop1 -> hop2 (whitelisted path)
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rsChain'
	option type 'local'
	option path '$TMPDIR/src/chain1.json'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rsChain.json" "$SINGBOX_TMPDIR/rs_rsChain.raw"
out=$(run_uc fetch 2>&1 || true)
echo "$out" | grep -qiE 'outside the whitelist|not a regular file|escaping' \
	|| { echo "$out"; fail "SEC-8: multi-hop chain escaping whitelist not rejected"; }
if [ -f "$SINGBOX_TMPDIR/rs_rsChain.json" ] || [ -f "$SINGBOX_TMPDIR/rs_rsChain.raw" ]; then
	fail "SEC-8: multi-hop chain should not have produced a file"
fi
pass "SEC-8: multi-hop symlink chain is rejected"

# ---- SEC-8: a symlinked PARENT directory escaping the whitelist is rejected ----
# /tmp/.../pdir is a symlink to a real dir OUTSIDE any whitelist prefix; the leaf
# /tmp/.../pdir/list.json then resolves (via the parent) to a path outside the
# whitelist. The old leaf-only lstat never inspected the parent. resolve_local_source
# canonicalises the parent hop, so the final real path lands outside and is rejected.
echo "-- SEC-8: symlinked-parent escape is rejected"
REALOUT=$(mktemp -d)                                   # outside /tmp on most CI? usually /tmp — so force a non-whitelisted leaf
mkdir -p "$REALOUT/d"; printf '{"version":1,"rules":[]}\n' > "$REALOUT/d/list.json"
# Only meaningful when REALOUT is NOT under a whitelist prefix; /tmp IS whitelisted,
# so emulate an out-of-whitelist parent by linking the parent to /proc (no list.json
# there → final path /proc/list.json is outside whitelist anyway under /proc).
ln -sf /proc "$TMPDIR/src/pdir"                        # parent symlink -> /proc (outside whitelist)
cat >"$TMPDIR/singbox-ui" <<EOF
config ruleset 'rsParent'
	option type 'local'
	option path '$TMPDIR/src/pdir/version'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR/rs_rsParent.json" "$SINGBOX_TMPDIR/rs_rsParent.raw"
out=$(run_uc fetch 2>&1 || true)
echo "$out" | grep -qiE 'outside the whitelist|not a regular file|escaping' \
	|| { echo "$out"; fail "SEC-8: symlinked-parent escape not rejected"; }
if [ -f "$SINGBOX_TMPDIR/rs_rsParent.json" ] || [ -f "$SINGBOX_TMPDIR/rs_rsParent.raw" ]; then
	fail "SEC-8: symlinked-parent escape should not have produced a file"
fi
rm -rf "$REALOUT"
pass "SEC-8: symlinked-parent escape is rejected"

# ---- regression: inbound nft_rules='1' is NOT treated as a ruleset ----
# Fixture: a tproxy inbound carrying nft_rules='1' and NO config ruleset section.
# The ruleset fetcher keys on UCI section KIND (sections_of_kind "ruleset"), so the
# inbound must never be iterated. Guard against the old bug where it walked every
# nft_rules='1' section regardless of kind (picking up tproxy inbounds -> staleness
# fired forever -> infinite reload). A behavioral/log assertion: with the bug, the
# fetcher would process 'tproxy_in' and log "unknown type 'tproxy' for tproxy_in";
# correctly scoped, it logs "no rule-sets configured (nft_rules=1)" and stops.
#
# Drive `fetch` (not `refresh`) — fetch calls cmd_fetch_rulesets directly, so the
# log is deterministic and not masked by the cold-cache reload backoff in refresh.
echo "-- inbound nft_rules='1' is not treated as a ruleset"
cat >"$TMPDIR/singbox-ui" <<'EOF'
config cache 'cache'
	option enabled '1'

config inbound 'tproxy_in'
	option type 'tproxy'
	option enabled '1'
	option nft_rules '1'
EOF
rm -f "$SINGBOX_TMPDIR"/rs_*.json
out=$(SINGBOX_NO_RELOAD=1 run_uc fetch 2>&1 || true)
echo "$out" | grep -q 'no rule-sets configured' \
	|| { echo "[$out]"; fail "inbound-only fixture should yield 'no rule-sets configured' (ruleset scoping broken)"; }
echo "$out" | grep -q 'tproxy_in' \
	&& { echo "[$out]"; fail "ruleset fetcher referenced the inbound 'tproxy_in' (treated inbound as ruleset)"; }
if ls "$SINGBOX_TMPDIR"/rs_*.json >/dev/null 2>&1; then
	fail "inbound nft_rules=1 wrongly produced an rs_*.json (treated as ruleset)"
fi
pass "inbound nft_rules='1' is not treated as a ruleset"

echo "OK"
