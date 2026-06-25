import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("awg nft fragment", () => {
  useGuest();

  it("emits v4+v6 masquerade when .conf contains v6 Address (prod path)", async () => {
    // Prod path: UCI carries type/enabled/ipv6_enabled/warp_storage (NO warp_address_v6).
    // v6addr is sourced from a pre-placed .conf in SINGBOX_TMPDIR — mirrors reconcile.
    const r = await exec(`
      set -e
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_nft_uci
      RAM=/tmp/awg_nft_ram
      trap 'rm -rf "$DST" "$UCFG" "$RAM"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_n'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option ipv6_enabled '1'" \
        "	option warp_storage 'ram'" \
        > "$UCFG/singbox-ui"

      # Pre-place .conf with v6 Address (confstore source of truth)
      mkdir -p "$RAM"
      cat > "$RAM/warp_n.conf" << 'WGEOF'
[Interface]
PrivateKey = PRIV==
Jc = 8
Jmin = 64
Jmax = 900
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
Address = 172.16.0.2/32
Address = 2606:4700::2/128
MTU = 1380
[Peer]
PublicKey = PUB==
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
WGEOF

      out=$(UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" ucode -L '${LIB}' -e '
        let n = require("plugins.awg_warp.nft");
        let uci_mod = require("uci");
        let uci_dir = getenv("UCI_CONFIG_DIR");
        let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
        print(n.fragment(cur));
      ')
      echo "$out" | grep -q 'oifname "warp_n" masquerade' && echo V4 || echo NOV4
      echo "$out" | grep -qi "ip6" && echo V6 || echo NOV6
      echo "$out" | grep -q 'table ip singbox_ui_awg_nat' && echo TABLEIP || echo NOTABLEIP
      echo "$out" | grep -q 'table ip6 singbox_ui_awg_nat6' && echo TABLEIP6 || echo NOTABLEIP6
      echo "$out" | grep -q 'table inet singbox_ui_awg_nat' && echo TABLEINET || echo NOTABLEINET
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("V4");
    expect(r.stdout).toContain("V6");
    expect(r.stdout).toContain("TABLEIP");
    expect(r.stdout).toContain("TABLEIP6");
    // double-NAT regression guard: v4 table must be ip-only, NOT inet (dual-stack)
    expect(r.stdout).toContain("NOTABLEINET");
  });

  it("omits ip6 table when .conf has no v6 Address (v4-only .conf)", async () => {
    // Negative case: same UCI (ipv6_enabled=1) but .conf contains no v6 Address.
    // nft.uc must NOT emit the ip6 masquerade table — v6 is gated on actual .conf content.
    const r = await exec(`
      set -e
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_nft_nov6_uci
      RAM=/tmp/awg_nft_nov6_ram
      trap 'rm -rf "$DST" "$UCFG" "$RAM"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_m'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option ipv6_enabled '1'" \
        "	option warp_storage 'ram'" \
        > "$UCFG/singbox-ui"

      # Pre-place v4-only .conf — no v6 Address line
      mkdir -p "$RAM"
      cat > "$RAM/warp_m.conf" << 'WGEOF'
[Interface]
PrivateKey = PRIV==
Jc = 8
Jmin = 64
Jmax = 900
S1 = 0
S2 = 0
S3 = 0
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4
Address = 172.16.0.2/32
MTU = 1380
[Peer]
PublicKey = PUB==
Endpoint = engage.cloudflareclient.com:2408
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
WGEOF

      out=$(UCI_CONFIG_DIR="$UCFG" SINGBOX_TMPDIR="$RAM" ucode -L '${LIB}' -e '
        let n = require("plugins.awg_warp.nft");
        let uci_mod = require("uci");
        let uci_dir = getenv("UCI_CONFIG_DIR");
        let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
        print(n.fragment(cur));
      ')
      echo "$out" | grep -q 'table ip singbox_ui_awg_nat' && echo TABLEIP || echo NOTABLEIP
      echo "$out" | grep -q 'table ip6 singbox_ui_awg_nat6' && echo TABLEIP6 || echo NOTABLEIP6
    `);
    expect(r.exitCode).toBe(0);
    // V4 masquerade must still be emitted
    expect(r.stdout).toContain("TABLEIP");
    // No v6 Address in .conf → no ip6 table even though ipv6_enabled=1
    expect(r.stdout).toContain("NOTABLEIP6");
  });
});

describe("awg descriptor", () => {
  useGuest();
  it("emit() returns {type:direct, tag, bind_interface} for a section name", async () => {
    const r = await exec(`
      set -e
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        require("plugins.awg_warp.protocols.awg_warp");
        let reg = require("builder.protocols.registry");
        let d = reg.get("outbound", "awg_warp");
        let out = d.emit({ ".name": "warp_x" });
        print(sprintf("%J", out));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.type).toBe("direct");
    expect(o.tag).toBe("warp_x");
    expect(o.bind_interface).toBe("warp_x");
  });
});
