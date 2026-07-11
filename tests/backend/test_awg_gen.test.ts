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
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      ucode -L '${LIB}' -e '
        let g = require("plugins.awg_warp.awggen");
        let bad = 0;
        for (let i = 0; i < 50; i++) {
          let p = g.generate({ mtu: 1280 });
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
});
