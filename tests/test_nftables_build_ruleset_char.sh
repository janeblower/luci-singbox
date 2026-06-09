#!/bin/sh
# tests/test_nftables_build_ruleset_char.sh
#
# Characterization gate for the build_ruleset refactor (S1-QUAL): splitting the
# ~92-line build_ruleset into emit_named_sets / emit_prerouting_chain /
# emit_output_chain is a PURE refactor — the emitted nft ruleset must be
# byte-identical before and after, across every branch (v4-only, v4+v6,
# router-out on/off, multi-iface, with/without rs_* sets).
#
# Why a git-baseline golden instead of committed .nft fixtures: the golden is
# generated at run time from the pre-refactor nftables.uc extracted from a
# pinned baseline commit, then compared against the current working-tree file
# over a fixed input matrix. This captures-then-compares inside ONE VM/CI run,
# so it needs no hand-authored fixtures (which could carry a stray byte and
# falsely pass/fail) and stays correct in environments where ucode can only be
# driven inside the VM. If the baseline commit is unreachable (e.g. a shallow
# clone) the test SKIPs rather than giving a false signal.
set -e

# Pre-refactor baseline: the commit whose nftables.uc still has the monolithic
# build_ruleset. The golden ruleset is emitted from THIS revision of the file.
BASELINE_REF=${SINGBOX_CHAR_BASELINE:-849e2b9}
SCRIPT_REL=luci-app-singbox-ui/root/usr/share/singbox-ui/nftables.uc
CUR_SCRIPT=$PWD/$SCRIPT_REL

if [ ! -x "$CUR_SCRIPT" ]; then
	echo "FAIL: $CUR_SCRIPT not present or not executable"
	exit 1
fi

# ucode is required to drive .uc. Skip cleanly when missing (mirrors
# test_nftables_emit.sh / test_generate.sh / test_nftables_uc.sh).
if command -v ucode >/dev/null 2>&1; then
	UCODE_BIN=ucode
	UCODE_LIB_FLAGS="-L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
elif [ -x "${UCODE_BIN:-}" ] && [ -d "${UCODE_STUB_DIR:-}" ]; then
	UCODE_LIB_FLAGS="-L $UCODE_STUB_DIR"
	[ -n "${UCODE_LIB_DIR:-}" ] && UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L $UCODE_LIB_DIR"
	UCODE_LIB_FLAGS="$UCODE_LIB_FLAGS -L ${UCODE_APP_LIB_DIR:-$PWD/luci-app-singbox-ui/root/usr/share/singbox-ui/lib}"
else
	echo "SKIP: ucode not available"
	exit 0
fi

# Materialize the pre-refactor golden script from the pinned baseline commit.
# If the baseline isn't reachable (shallow clone, detached export), SKIP — a
# missing golden source must not masquerade as a pass or a failure.
if ! git rev-parse --verify "${BASELINE_REF}^{commit}" >/dev/null 2>&1; then
	echo "SKIP: baseline commit ${BASELINE_REF} unreachable (shallow clone?)"
	exit 0
fi
GOLD_SCRIPT=$(mktemp /tmp/singbox-char-gold.XXXXXX.uc)
trap 'rm -f "$GOLD_SCRIPT" "$RS"/rs_char_*.json' EXIT
if ! git show "${BASELINE_REF}:${SCRIPT_REL}" > "$GOLD_SCRIPT" 2>/dev/null; then
	echo "SKIP: ${SCRIPT_REL} absent at baseline ${BASELINE_REF}"
	exit 0
fi

RS=/tmp/singbox-ui
mkdir -p "$RS"
rm -f "$RS"/rs_char_*.json

emit() { # $1=script, rest=emit args
	_s=$1; shift
	# shellcheck disable=SC2086
	"$UCODE_BIN" $UCODE_LIB_FLAGS "$_s" emit "$@"
}

check() { # $1=label, then emit args; asserts current == golden, byte-for-byte
	label=$1; shift
	want=$(emit "$GOLD_SCRIPT" "$@")
	got=$(emit "$CUR_SCRIPT" "$@")
	if [ "$got" != "$want" ]; then
		echo "FAIL: $label drifted from pre-refactor golden"
		printf '%s\n' "$want" > /tmp/singbox-char-want.txt
		printf '%s\n' "$got"  > /tmp/singbox-char-got.txt
		diff -u /tmp/singbox-char-want.txt /tmp/singbox-char-got.txt || true
		rm -f /tmp/singbox-char-want.txt /tmp/singbox-char-got.txt
		exit 1
	fi
	echo "  PASS: $label byte-identical"
}

echo "-- build_ruleset characterization matrix (golden = ${BASELINE_REF})"

# emit argv positions: port v4 v6 iface[,iface] [mark] [mask] [router_out]
check m_fakeip_v4_only     7893 "198.18.0.0/15" ""          "br-lan"
check m_fakeip_v4_v6       7895 "198.18.0.0/15" "fc00::/18" "br-lan"
check m_router_out_on      7895 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1 1
check m_multi_iface        7893 "198.18.0.0/15" ""          "br-lan,br-guest"

# Invalid/empty PORT → validate_port() returns null → emit_prerouting_chain's
# `if (port_n != null)` tproxy block is SKIPPED. The 6-scenario base matrix
# always passed a valid port, so the tproxy-skipped branch of the refactored
# emit_prerouting_chain was never byte-compared. An empty-string PORT is a
# valid positional (emit only requires argv>=5: PORT V4 V6 IFACE all present),
# so it drives the skip through the real `emit` entrypoint.
check m_port_empty_skip    ""   "198.18.0.0/15" "fc00::/18" "br-lan"

# Custom mark with mark != mask (0x40 & 0xc0 == 0x40, so fwmark_pair keeps it),
# dual-stack + router_out. The base matrix only ever used 0x1/0x1 where
# mark == mask, so a helper param-order slip (mark/mask swapped in
# emit_prerouting_chain's socket-mark `mark & mask` or the tproxy
# `mark and 0x%x == 0x%x` clause) would stay invisible. Distinct mark/mask
# values make any such swap diverge from the golden.
check m_mark_ne_mask_rout  7895 "198.18.0.0/15" "fc00::/18" "br-lan" 0x40 0xc0 1

# rs_* set with a tcp port range — exercises emit_named_sets' rule-set loop and
# the rs_* decision rules in both prerouting and (when router_out=1) output.
cat >"$RS/rs_char_set.json" <<'JSON'
{ "rules": [ { "ip_cidr": ["1.2.3.0/24","fe80::/10"], "network":"tcp", "port_range":"80:443" } ] }
JSON
check m_with_ruleset       7893 "198.18.0.0/15" "fc00::/18" "br-lan"
check m_with_ruleset_rout  7893 "198.18.0.0/15" "fc00::/18" "br-lan" 0x1 0x1 1

rm -f "$RS"/rs_char_*.json
echo "OK"
