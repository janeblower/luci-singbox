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
});
