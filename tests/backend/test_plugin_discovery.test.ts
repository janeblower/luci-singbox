import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

describe("test_plugin_discovery", () => {
  useGuest();

  it("registry accepts the extended hook superset and exposes accessors", async () => {
    const r = await exec(`ucode -L '${LIB}' -e '
      let reg = require("plugins.registry");
      reg.register({
        name: "p1", version: "9",
        rpcd: { methods: { foo: function(){ return 1; } }, acl_read: ["foo"], acl_write: [] },
        lifecycle: { apply: function(c){ return "a"; } },
        nft: { fragment: function(c){ return "chain x {}"; } },
      });
      let methods = reg.get_rpcd_methods();
      let acl = reg.get_rpcd_acl();
      let lc = reg.get_lifecycle();
      let nf = reg.get_nft_fragments();
      print(sprintf("%J", {
        has_foo: type(methods.foo) === "function",
        acl_read: acl.read, acl_write: acl.write,
        lc_count: length(lc), nf_count: length(nf),
        names: map(reg.get_all(), function(p){ return p.name; }),
      }));
    '`);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.has_foo).toBe(true);
    expect(o.acl_read).toEqual(["foo"]);
    expect(o.lc_count).toBe(1);
    expect(o.nf_count).toBe(1);
    expect(o.names).toContain("p1");
  });
});
