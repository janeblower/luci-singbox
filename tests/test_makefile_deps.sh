#!/bin/sh
# Guards the package dependency declarations across the three-way split.
# The deps are declared in TWO places that MUST stay in sync (CLAUDE.md
# "Пакетный менеджер (apk-only)") — the buildroot Makefiles and the REAL
# shipped .apk (scripts/build-apk.sh, the primary delivery path):
#
#   backend (singbox-ui):
#     - singbox-ui/Makefile          DEPENDS       (+pkg syntax)
#     - scripts/build-apk.sh         SINGBOX_DEPENDS
#   LuCI frontend (luci-app-singbox-ui):
#     - luci-app-singbox-ui/Makefile LUCI_DEPENDS   (+singbox-ui; luci-base
#                                                    is implicit via luci.mk)
#     - scripts/build-apk.sh         LUCIAPP_DEPENDS (singbox-ui luci-base)
#
# Invariants:
#   - nftables is NOT an explicit backend dep (ships in OpenWrt base / fw4).
#   - jq is NOT a backend dep (not used on-device).
#   - curl is present in the backend set (subscription fetch uses it).
#   - kmod-nft-socket + kmod-nft-tproxy are present in the backend set
#     (nftables.uc emits `socket transparent` / `tproxy ... to`, which need
#     these kernel modules).
#   - ucode + ucode-mod-fs are present in the backend set (shipped .uc handlers
#     require('fs')).
#   - bbolt-client is present in the backend set (cache.db reader package).
#   - Each package's two dependency SETS are equivalent — the .apk path (which
#     install.sh / feed users actually get) must not silently drift from the
#     buildroot path.
set -eu

SINGBOX_MK="singbox-ui/Makefile"
LUCIAPP_MK="luci-app-singbox-ui/Makefile"
BUILDSH="scripts/build-apk.sh"
for f in "$SINGBOX_MK" "$LUCIAPP_MK" "$BUILDSH"; do
    [ -f "$f" ] || { echo "FAIL: $f missing"; exit 1; }
done

# Required runtime deps the backend set must carry, in BOTH declarations.
BACKEND_REQUIRED="bbolt-client sing-box curl ucode ucode-mod-fs kmod-nft-socket kmod-nft-tproxy"

# --- Normalizers: extract each dependency set into a sorted one-per-line list ---
# libc is implicit in the buildroot path; build-apk.sh lists it explicitly
# because apk needs it. Drop libc from both before diffing so that asymmetry
# doesn't trip the equivalence check.
#
# luci-base is implicit in the buildroot LuCI path (luci.mk adds it), but
# build-apk.sh lists it explicitly. For the luci-app set we add luci-base to
# the Makefile side before diffing so the two sets line up.
norm_list() {
    tr ' ' '\n' \
        | sed 's/^+//' \
        | grep -v '^$' \
        | grep -v '^libc$' \
        | LC_ALL=C sort -u
}

# Backend Makefile: `DEPENDS:=+bbolt-client +sing-box +curl ...`
singbox_mk_set() {
    grep '^[[:space:]]*DEPENDS' "$SINGBOX_MK" \
        | sed 's/^[[:space:]]*DEPENDS[[:space:]]*:*=//' \
        | norm_list
}
# Backend build-apk.sh: `SINGBOX_DEPENDS="libc bbolt-client sing-box curl ..."`
singbox_apk_set() {
    grep '^SINGBOX_DEPENDS=' "$BUILDSH" \
        | sed 's/^SINGBOX_DEPENDS=//; s/"//g' \
        | norm_list
}
# LuCI Makefile: `LUCI_DEPENDS:=+singbox-ui` (+ implicit luci-base via luci.mk).
luciapp_mk_set() {
    { grep '^[[:space:]]*LUCI_DEPENDS' "$LUCIAPP_MK" \
        | sed 's/^[[:space:]]*LUCI_DEPENDS[[:space:]]*:*=//'
      # luci-base is implicit via luci.mk — add it to match the .apk side.
      echo "luci-base"
    } | norm_list
}
# LuCI build-apk.sh: `LUCIAPP_DEPENDS="libc singbox-ui luci-base"`
luciapp_apk_set() {
    grep '^LUCIAPP_DEPENDS=' "$BUILDSH" \
        | sed 's/^LUCIAPP_DEPENDS=//; s/"//g' \
        | norm_list
}

SINGBOX_MK_LINE="$(grep '^[[:space:]]*DEPENDS' "$SINGBOX_MK")"
SINGBOX_APK_LINE="$(grep '^SINGBOX_DEPENDS=' "$BUILDSH")"

# --- nftables / jq must NOT be explicit BACKEND dependencies in either place ---
echo "$SINGBOX_MK_LINE"  | grep -q '+nftables' \
    && { echo "FAIL: +nftables should not be in singbox-ui/Makefile DEPENDS"; exit 1; } || true
echo "$SINGBOX_APK_LINE" | grep -qw 'nftables' \
    && { echo "FAIL: nftables should not be in SINGBOX_DEPENDS (build-apk.sh)"; exit 1; } || true
echo "$SINGBOX_MK_LINE"  | grep -q '+jq' \
    && { echo "FAIL: +jq should not be in singbox-ui/Makefile DEPENDS"; exit 1; } || true
echo "$SINGBOX_APK_LINE" | grep -qw 'jq' \
    && { echo "FAIL: jq should not be in SINGBOX_DEPENDS (build-apk.sh)"; exit 1; } || true

# --- Required backend deps present in BOTH backend declarations ---
sb_mk="$(singbox_mk_set)"
sb_apk="$(singbox_apk_set)"
for dep in $BACKEND_REQUIRED; do
    printf '%s\n' "$sb_mk"  | grep -qx "$dep" \
        || { echo "FAIL: singbox-ui/Makefile DEPENDS missing '$dep'"; exit 1; }
    printf '%s\n' "$sb_apk" | grep -qx "$dep" \
        || { echo "FAIL: SINGBOX_DEPENDS (build-apk.sh) missing '$dep' — the shipped .apk would not pull it"; exit 1; }
done

# --- (a) backend sets equivalent ---
if [ "$sb_mk" != "$sb_apk" ]; then
    tmp_mk="$(mktemp)"; tmp_apk="$(mktemp)"
    trap 'rm -f "$tmp_mk" "$tmp_apk"' EXIT
    printf '%s\n' "$sb_mk"  > "$tmp_mk"
    printf '%s\n' "$sb_apk" > "$tmp_apk"
    echo "FAIL: singbox-ui/Makefile DEPENDS and SINGBOX_DEPENDS (build-apk.sh) diverge."
    echo "  Makefile-only deps:"
    grep -vxF -f "$tmp_apk" "$tmp_mk" | sed 's/^/    /' || true
    echo "  build-apk.sh-only deps:"
    grep -vxF -f "$tmp_mk" "$tmp_apk" | sed 's/^/    /' || true
    exit 1
fi
echo "  PASS: backend (singbox-ui) deps equivalent in Makefile and build-apk.sh"

# --- (b) luci-app sets equivalent (Makefile + implicit luci-base) ---
la_mk="$(luciapp_mk_set)"
la_apk="$(luciapp_apk_set)"
# singbox-ui + luci-base must be in both.
for dep in singbox-ui luci-base; do
    printf '%s\n' "$la_mk"  | grep -qx "$dep" \
        || { echo "FAIL: luci-app-singbox-ui deps (Makefile+implicit) missing '$dep'"; exit 1; }
    printf '%s\n' "$la_apk" | grep -qx "$dep" \
        || { echo "FAIL: LUCIAPP_DEPENDS (build-apk.sh) missing '$dep'"; exit 1; }
done
if [ "$la_mk" != "$la_apk" ]; then
    tmp_mk="$(mktemp)"; tmp_apk="$(mktemp)"
    trap 'rm -f "$tmp_mk" "$tmp_apk"' EXIT
    printf '%s\n' "$la_mk"  > "$tmp_mk"
    printf '%s\n' "$la_apk" > "$tmp_apk"
    echo "FAIL: luci-app-singbox-ui deps (Makefile LUCI_DEPENDS + implicit luci-base)"
    echo "      and LUCIAPP_DEPENDS (build-apk.sh) diverge."
    echo "  Makefile-only deps:"
    grep -vxF -f "$tmp_apk" "$tmp_mk" | sed 's/^/    /' || true
    echo "  build-apk.sh-only deps:"
    grep -vxF -f "$tmp_mk" "$tmp_apk" | sed 's/^/    /' || true
    exit 1
fi
echo "  PASS: luci-app-singbox-ui deps equivalent in Makefile and build-apk.sh"

echo "PASS"
