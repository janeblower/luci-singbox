import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

describe("awggen", () => {
  useGuest();

  it("target=warp forces S=0 and H=1,2,3,4 across 50 generations", async () => {
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let g = require("plugins.awg_warp.awggen");
        let bad = 0;
        for (let i = 0; i < 50; i++) {
          let p = g.generate({ target: "warp", mimic: "auto", mtu: 1280 });
          if (p.s1 != 0 || p.s2 != 0 || p.s3 != 0 || p.s4 != 0) bad++;
          if (p.h1 != 1 || p.h2 != 2 || p.h3 != 3 || p.h4 != 4) bad++;
          if (!(p.jc >= 1 && p.jmin < p.jmax)) bad++;
        }
        print(sprintf("%J", { bad }));
      '
    `);
    expect(r.exitCode).toBe(0);
    expect(JSON.parse(r.stdout).bad).toBe(0);
  });

  it("selfhosted validation rejects S1+56==S2 and non-distinct H", async () => {
    const r = await exec(`
      SRC="${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let g = require("plugins.awg_warp.awggen");
        let e1 = g.validate_selfhosted({ s1: 10, s2: 66, h1: 5, h2: 5, h3: 7, h4: 8, jmin: 8, jmax: 80 }, 1420);
        print(sprintf("%J", { has_errors: length(e1) > 0 }));
      '
    `);
    expect(r.exitCode).toBe(0);
    expect(JSON.parse(r.stdout).has_errors).toBe(true);
  });
});
