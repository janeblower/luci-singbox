import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("awg nft fragment", () => {
  useGuest();
  it("emits a masquerade chain for an enabled iface (v4+v6)", async () => {
    const r = await exec(`
      set -e
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      UCFG=/tmp/awg_nft_uci
      trap 'rm -rf "$DST" "$UCFG"' EXIT
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/ 2>/dev/null || true

      mkdir -p "$UCFG"
      printf '%s\n' \
        "config outbound 'warp_n'" \
        "	option type 'awg_warp'" \
        "	option enabled '1'" \
        "	option ipv6_enabled '1'" \
        "	option warp_address_v6 '2606:4700::2/128'" \
        > "$UCFG/singbox-ui"

      out=$(UCI_CONFIG_DIR="$UCFG" ucode -L '${LIB}' -e '
        let n = require("plugins.awg_warp.nft");
        let uci_mod = require("uci");
        let uci_dir = getenv("UCI_CONFIG_DIR");
        let cur = uci_dir ? uci_mod.cursor(uci_dir) : uci_mod.cursor();
        print(n.fragment(cur));
      ')
      echo "$out" | grep -q 'oifname "warp_n" masquerade' && echo V4 || echo NOV4
      echo "$out" | grep -qi "ip6" && echo V6 || echo NOV6
    `);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("V4");
    expect(r.stdout).toContain("V6");
  });
});

describe("awg descriptor", () => {
  useGuest();
  it("emit() returns {type:direct, tag, bind_interface} for a section name", async () => {
    const r = await exec(`
      set -e
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        require("plugins.awg_warp.descriptor");
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
