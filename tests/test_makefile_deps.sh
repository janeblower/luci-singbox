#!/bin/sh
# Guards the package dependency declarations. Two places declare deps and MUST
# stay in sync (CLAUDE.md "Пакетный менеджер (apk-only)"):
#   - luci-singbox-ui/Makefile  LUCI_DEPENDS  (buildroot path, +pkg syntax)
#   - scripts/build-apk.sh      APP_DEPENDS   (the REAL shipped .apk — primary path)
#
# Invariants:
#   - nftables is NOT an explicit dep (ships in OpenWrt base / fw4).
#   - curl is present (subscription fetch uses it).
#   - kmod-nft-socket + kmod-nft-tproxy are present in BOTH (nftables.uc emits
#     `socket transparent` / `tproxy ... to`, which need these kernel modules).
#   - ucode-mod-fs is present in BOTH (shipped .uc handlers require('fs')).
#   - The two dependency SETS are equivalent — the .apk path (which install.sh /
#     feed users actually get) must not silently drift from the buildroot path.
set -eu

MK="luci-singbox-ui/Makefile"
BUILDSH="scripts/build-apk.sh"
[ -f "$MK" ]      || { echo "FAIL: $MK missing"; exit 1; }
[ -f "$BUILDSH" ] || { echo "FAIL: $BUILDSH missing"; exit 1; }

# Required runtime deps that BOTH lists must carry.
REQUIRED="curl ucode-mod-fs kmod-nft-socket kmod-nft-tproxy"

# --- Extract + normalize each dependency set into a sorted, one-per-line list ---
# Makefile: `LUCI_DEPENDS:=+luci-base +sing-box +curl ...` — strip the leading
# `+` from each token. (libc is implicit in the buildroot path; build-apk.sh
# lists it explicitly because apk needs it. Drop libc from both before diffing
# so that asymmetry doesn't trip the equivalence check.)
mk_set() {
    grep '^LUCI_DEPENDS' "$MK" \
        | sed 's/^LUCI_DEPENDS[[:space:]]*:*=//' \
        | tr ' ' '\n' \
        | sed 's/^+//' \
        | grep -v '^$' \
        | grep -v '^libc$' \
        | LC_ALL=C sort -u
}
# build-apk.sh: `APP_DEPENDS="libc luci-base sing-box curl ..."`.
apk_set() {
    grep '^APP_DEPENDS=' "$BUILDSH" \
        | sed 's/^APP_DEPENDS=//; s/"//g' \
        | tr ' ' '\n' \
        | grep -v '^$' \
        | grep -v '^libc$' \
        | LC_ALL=C sort -u
}

MK_LINE="$(grep '^LUCI_DEPENDS' "$MK")"
APK_LINE="$(grep '^APP_DEPENDS=' "$BUILDSH")"

# --- nftables must NOT be an explicit dependency in either list ---
echo "$MK_LINE"  | grep -q '+nftables'    && { echo "FAIL: +nftables should be removed from LUCI_DEPENDS"; exit 1; } || true
echo "$APK_LINE" | grep -qw 'nftables'     && { echo "FAIL: nftables should be removed from APP_DEPENDS"; exit 1; } || true

# --- Required deps present in BOTH lists ---
mk="$(mk_set)"
apk="$(apk_set)"
for dep in $REQUIRED; do
    printf '%s\n' "$mk"  | grep -qx "$dep" || { echo "FAIL: LUCI_DEPENDS (Makefile) missing '$dep'"; exit 1; }
    printf '%s\n' "$apk" | grep -qx "$dep" || { echo "FAIL: APP_DEPENDS (build-apk.sh) missing '$dep' — the shipped .apk would not pull it"; exit 1; }
done

# --- The two dependency sets must be equivalent (no silent drift) ---
if [ "$mk" != "$apk" ]; then
    tmp_mk="$(mktemp)"; tmp_apk="$(mktemp)"
    trap 'rm -f "$tmp_mk" "$tmp_apk"' EXIT
    printf '%s\n' "$mk"  > "$tmp_mk"
    printf '%s\n' "$apk" > "$tmp_apk"
    echo "FAIL: LUCI_DEPENDS (Makefile) and APP_DEPENDS (build-apk.sh) diverge."
    echo "  Makefile-only deps:"
    grep -vxF -f "$tmp_apk" "$tmp_mk" | sed 's/^/    /' || true
    echo "  build-apk.sh-only deps:"
    grep -vxF -f "$tmp_mk" "$tmp_apk" | sed 's/^/    /' || true
    exit 1
fi

echo "PASS"
