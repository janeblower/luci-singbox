// tests/backend/test_awg_confstore.test.ts
import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
	process.env.SB_VM_LIB ??
	"/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("awg confstore: path + render + parse", () => {
	useGuest();

	it("conf_path resolves ram/flash and round-trips render_conf→parse_full", async () => {
		const r = await exec(`
      SRC="${WORK}/plugins/awg_warp/lib"
      DST="${LIB}/plugins/awg_warp"
      trap 'rm -rf "$DST"' EXIT
      mkdir -p "$DST"; cp -r "$SRC"/. "$DST"/ 2>/dev/null || true

      SINGBOX_TMPDIR=/tmp/sb_ram SB_AWG_FLASH_DIR=/etc/sb_flash \
        ucode -L '${LIB}' -e '
        let c = require("plugins.awg_warp.confstore");
        let wg = {
          private_key: "PRIV==", peer_public_key: "PUB==",
          address_v4: "172.16.0.2/32", address_v6: "2606:4700::2/128",
          endpoint: "engage.cloudflareclient.com:2408",
          jc: 8, jmin: 64, jmax: 900, s1: 0, s2: 0, s3: 0, s4: 0,
          h1: 1, h2: 2, h3: 3, h4: 4, i1: "<b 0xdead>",
        };
        let conf = c.render_conf(wg, 1280, true);
        let back = c.parse_full(conf);
        let setc = c.render_setconf(wg);
        print(sprintf("%J", {
          ram:   c.conf_path("warp_us", "ram"),
          flash: c.conf_path("warp_us", "flash"),
          rt_priv: back.private_key, rt_pub: back.peer_public_key,
          rt_ep: back.endpoint, rt_v4: back.address_v4, rt_v6: back.address_v6,
          rt_jc: back.jc, rt_i1: back.i1,
          setconf_has_addr: (index(setc, "Address") >= 0),
          setconf_has_mtu:  (index(setc, "MTU") >= 0),
        }));
      '
    `);
		expect(r.exitCode).toBe(0);
		const o = JSON.parse(r.stdout);
		expect(o.ram).toBe("/tmp/sb_ram/warp_us.conf");
		expect(o.flash).toBe("/etc/sb_flash/warp_us.conf");
		expect(o.rt_priv).toBe("PRIV==");
		expect(o.rt_pub).toBe("PUB==");
		expect(o.rt_ep).toBe("engage.cloudflareclient.com:2408");
		expect(o.rt_v4).toBe("172.16.0.2/32");
		expect(o.rt_v6).toBe("2606:4700::2/128");
		expect(o.rt_jc).toBe(8);
		expect(o.rt_i1).toBe("<b 0xdead>");
		expect(o.setconf_has_addr).toBe(false);
		expect(o.setconf_has_mtu).toBe(false);
	});
});
