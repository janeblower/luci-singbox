#!/bin/sh
# tests/test_nft_rulesets_uc.sh
# Drives nft-rulesets.uc local-source path validation with a fixture UCI dir + a fake sing-box. No network.
set -e

# Mirror test_generate.sh: skip if ucode/uci-mod unavailable on dev box.
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

SUB_UC=luci-singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc
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
# Structural check: the local-ruleset error branch must explicitly unlink
# raw_path so a partial copy can't poison subsequent runs.
echo "-- C2.1.16: local-ruleset cp-failure branch removes raw_path"
grep -qE 'fs\.unlink\(raw_path\)' \
	"luci-singbox-ui/root/usr/share/singbox-ui/nft-rulesets.uc" \
	|| fail "nft-rulesets.uc: missing fs.unlink(raw_path) cleanup in local branch"
pass "nft-rulesets.uc: local cp-failure cleans up raw_path"

# ---- S3-3: symlink whose target escapes the whitelist is rejected ----
# The symlink path itself is under /tmp (whitelisted), but its target resolves
# to /proc/version, under no whitelist prefix. cp would follow it; the handler
# resolves the link with fs.readlink (lstat exposes no target field) and
# re-checks the prefix guard, which must reject it.
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

echo "OK"
