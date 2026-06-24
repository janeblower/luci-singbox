import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("awg iface helpers", () => {
  useGuest();
  it("sanitizes interface names and computes MTU via override", async () => {
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let h = require("plugins.awg_warp.iface");
        print(sprintf("%J", {
          n1: h.iface_name("warp_us"),
          n2: h.iface_name("My WARP #1!! tooooo long name"),
          n3: h.iface_name(""),
          mtu_override: h.effective_mtu({}, "1380"),
          wan_mtu_positive: (h.wan_mtu({}) > 0),
        }));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.n1).toBe("warp_us");
    expect(o.n2).toMatch(/^[a-z0-9_]{1,15}$/);
    expect(o.n3).toBe("awg");
    expect(o.mtu_override).toBe(1380);
    expect(o.wan_mtu_positive).toBe(true);
  });
});

describe("awg reconcile", () => {
  useGuest();

  it("apply issues native ip/awg commands; setconf excludes Address/MTU; addrlabel gated on ipv6", async () => {
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_rci_uci
      LOG=/tmp/awg_rci_cmds
      SETCONF=/tmp/awg_rci_sc
      M_IP=/tmp/awg_rci_ip
      M_AWG=/tmp/awg_rci_awg
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$SETCONF" "$M_IP" "$M_AWG"' EXIT
      mkdir -p "$DST" && cp "$SRC"/*.uc "$DST"/ 2>/dev/null

      rm -f "$LOG"
      # Write mock stubs — printf expands shell vars into the script body at write time
      printf '#!/bin/sh\necho "ip $@" >> %s\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\necho "awg $@" >> %s\n[ "$1" = "setconf" ] && cp "$3" %s 2>/dev/null\nexit 0\n' "$LOG" "$SETCONF" > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      # Seed UCI config using UCI_CONFIG_DIR seam (uci.cursor() reads from this dir)
      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_t'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_private_key 'PRIV=='" \
        "	option warp_peer_public_key 'PUB=='" \
        "	option warp_address_v4 '172.16.0.2/32'" \
        "	option warp_address_v6 '2606:4700::2/128'" \
        "	option warp_endpoint 'engage.cloudflareclient.com:2408'" \
        "	option awg_jc '8'" \
        "	option awg_jmin '64'" \
        "	option awg_jmax '900'" \
        "	option ipv6_enabled '1'" \
        "	option mtu_override '1380'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      setconf=$(cat "$SETCONF" 2>/dev/null || true)
      # grep -c prints count even on 0 matches (exits 1); || true suppresses that
      # exit under set -e. Arithmetic +0 coerces empty/missing to 0.
      has_link=$(grep -c "link add dev warp_t type amneziawg" "$LOG" 2>/dev/null || true); has_link=$((has_link+0))
      has_v6=$(grep -c "addr add 2606:4700::2/128" "$LOG" 2>/dev/null || true); has_v6=$((has_v6+0))
      has_mtu=$(grep -c "mtu 1380" "$LOG" 2>/dev/null || true); has_mtu=$((has_mtu+0))
      has_label=$(grep -c "addrlabel add" "$LOG" 2>/dev/null || true); has_label=$((has_label+0))
      bad_setconf=$(printf '%s' "$setconf" | grep -ci '^Address\|^MTU' 2>/dev/null || true); bad_setconf=$((bad_setconf+0))
      printf '{"link":%d,"v6":%d,"mtu":%d,"label":%d,"bad_setconf":%d}\n' \
        "$has_link" "$has_v6" "$has_mtu" "$has_label" "$bad_setconf"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.link).toBeGreaterThan(0);
    expect(o.v6).toBeGreaterThan(0);
    expect(o.mtu).toBeGreaterThan(0);
    expect(o.label).toBeGreaterThan(0);
    expect(o.bad_setconf).toBe(0);
  });

  it("FIX-1: disabling a section (enabled=0) also removes addrlabel entries", async () => {
    // Prove the addrlabel leak fix: enable a section with ipv6, apply, then set
    // enabled=0, apply again — the second apply must emit BOTH link del AND
    // addrlabel del for that interface (not just link del as before the fix).
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix1_uci
      LOG=/tmp/awg_fix1_cmds
      M_IP=/tmp/awg_fix1_ip
      M_AWG=/tmp/awg_fix1_awg
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$M_IP" "$M_AWG"' EXIT
      mkdir -p "$DST" && cp "$SRC"/*.uc "$DST"/ 2>/dev/null

      printf '#!/bin/sh\necho "ip $@" >> %s\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\nexit 0\n' > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      mkdir -p "$UCFG"
      # First apply: section enabled=1 with ipv6
      printf '%s\n' \
        "config outbound 'warp_dis'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_private_key 'PRIV=='" \
        "	option warp_peer_public_key 'PUB=='" \
        "	option warp_address_v4 '10.0.0.2/32'" \
        "	option warp_address_v6 '2606:4700::9/128'" \
        "	option warp_endpoint 'engage.cloudflareclient.com:2408'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      rm -f "$LOG"
      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Second apply: same section but enabled=0 (simulate user disabling it)
      printf '%s\n' \
        "config outbound 'warp_dis'" \
        "	option type 'awg_warp'" \
        "	option enabled '0'" \
        "	option warp_private_key 'PRIV=='" \
        "	option warp_peer_public_key 'PUB=='" \
        "	option warp_address_v4 '10.0.0.2/32'" \
        "	option warp_address_v6 '2606:4700::9/128'" \
        "	option warp_endpoint 'engage.cloudflareclient.com:2408'" \
        "	option ipv6_enabled '1'" \
        > "$UCFG/singbox-ui"

      rm -f "$LOG"
      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # The second apply (disable path) must emit link del AND addrlabel del
      has_link_del=$(grep -c "link del dev warp_dis" "$LOG" 2>/dev/null || true); has_link_del=$((has_link_del+0))
      has_addrlabel_del=$(grep -c "addrlabel del prefix 2606:4700::9/128" "$LOG" 2>/dev/null || true); has_addrlabel_del=$((has_addrlabel_del+0))
      has_default_del=$(grep -c "addrlabel del prefix ::/0" "$LOG" 2>/dev/null || true); has_default_del=$((has_default_del+0))
      printf '{"link_del":%d,"addrlabel_del":%d,"default_del":%d}\n' \
        "$has_link_del" "$has_addrlabel_del" "$has_default_del"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.link_del).toBeGreaterThan(0);
    expect(o.addrlabel_del).toBeGreaterThan(0);
    expect(o.default_del).toBeGreaterThan(0);
  });

  it("FIX-2: malicious warp_address_v4 is sanitized — ip addr add is not called with injected content", async () => {
    // Prove the safe_cidr sanitizer: an address containing shell metacharacters
    // must NOT reach the `ip addr add` command — the interface must not be
    // brought up with the bad address, and no marker file must be created.
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_fix2_uci
      LOG=/tmp/awg_fix2_cmds
      M_IP=/tmp/awg_fix2_ip
      M_AWG=/tmp/awg_fix2_awg
      MARKER=/tmp/awg_fix2_pwned
      trap 'rm -rf "$DST" "$UCFG" "$LOG" "$M_IP" "$M_AWG" "$MARKER"' EXIT
      mkdir -p "$DST" && cp "$SRC"/*.uc "$DST"/ 2>/dev/null

      rm -f "$MARKER"
      printf '#!/bin/sh\necho "ip $@" >> %s\n# execute any inline command passed as an arg (simulates injection)\neval "$@" 2>/dev/null || true\nexit 0\n' "$LOG" > "$M_IP"
      printf '#!/bin/sh\nexit 0\n' > "$M_AWG"
      chmod +x "$M_IP" "$M_AWG"

      mkdir -p "$UCFG"
      # Malicious address: would inject a command if passed unsanitized to shell
      printf '%s\n' \
        "config outbound 'warp_evil'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option warp_private_key 'PRIV=='" \
        "	option warp_peer_public_key 'PUB=='" \
        "	option warp_address_v4 '1.2.3.4/32; touch \${MARKER}'" \
        "	option warp_address_v6 ''" \
        "	option warp_endpoint 'engage.cloudflareclient.com:2408'" \
        "	option ipv6_enabled '0'" \
        > "$UCFG/singbox-ui"

      IP_BIN="$M_IP" AWG_BIN="$M_AWG" UCI_CONFIG_DIR="$UCFG" \
        ucode -L '${LIB}' -e '
          let rc = require("plugins.awg_warp.reconcile");
          let uci_mod = require("uci");
          let uci_dir = getenv("UCI_CONFIG_DIR");
          let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
          rc.apply(cur);
        ' 2>/dev/null || true

      # Marker must NOT exist (injection was blocked by safe_cidr)
      marker_exists=0
      [ -f "$MARKER" ] && marker_exists=1
      # ip addr add must not have been called with the evil address
      addr_add_evil=$(grep -c "addr add.*touch" "$LOG" 2>/dev/null || true); addr_add_evil=$((addr_add_evil+0))
      printf '{"marker_exists":%d,"addr_add_evil":%d}\n' "$marker_exists" "$addr_add_evil"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.marker_exists).toBe(0);
    expect(o.addr_add_evil).toBe(0);
  });
});
