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
