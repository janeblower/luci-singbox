import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";

// Seed a UCI tree whose `plugins` section carries the given enable flags, e.g.
// uciWith({ p1: true }) -> option p1_enabled '1'.
function uciWith(flags: Record<string, boolean>, dir: string): string {
  const lines = ["config singbox-ui 'plugins'"];
  for (const [name, on] of Object.entries(flags))
    lines.push(`\toption ${name}_enabled '${on ? "1" : "0"}'`);
  return `mkdir -p ${dir} && printf '%s\\n' ${lines
    .map((l) => `'${l}'`)
    .join(" ")} > ${dir}/singbox-ui`;
}

describe("test_plugin_discovery", () => {
  useGuest();

  it("enabled plugin: registry exposes rpcd/lifecycle/nft hooks", async () => {
    const dir = "/tmp/plug_en_uci";
    const r = await exec(`
      ${uciWith({ p1: true }, dir)}
      UCI_CONFIG_DIR=${dir} ucode -L '${LIB}' -e '
        let reg = require("plugins.registry");
        reg.register({
          name: "p1", version: "9",
          rpcd: { methods: { foo: function(){ return 1; } }, acl_read: ["foo"], acl_write: [] },
          lifecycle: { apply: function(c){ return "a"; } },
          nft: { fragment: function(c){ return "chain x {}"; } },
        });
        print(sprintf("%J", {
          has_foo: type(reg.get_rpcd_methods().foo) === "function",
          lc_count: length(reg.get_lifecycle()),
          nf_count: length(reg.get_nft_fragments()),
          names: map(reg.get_all(), function(p){ return p.name; }),
        }));
      '
      rm -rf ${dir}
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.has_foo).toBe(true);
    expect(o.lc_count).toBe(1);
    expect(o.nf_count).toBe(1);
    expect(o.names).toContain("p1");
  });

  // F-27: the enable toggle used to be frontend-only — every hook ran regardless,
  // so a plugin switched off in the UI kept creating its interface and NAT table
  // on the next restart. Hooks are gated on the flag now; get_all() still lists
  // the plugin, or the Plugins tab would have nothing left to switch back on.
  it("disabled plugin: no hooks take effect, but it is still listed", async () => {
    const dir = "/tmp/plug_dis_uci";
    const r = await exec(`
      ${uciWith({ p1: false }, dir)}
      UCI_CONFIG_DIR=${dir} ucode -L '${LIB}' -e '
        let reg = require("plugins.registry");
        let ran = false;
        reg.register({
          name: "p1", version: "9",
          rpcd: { methods: { foo: function(){ return 1; } } },
          lifecycle: { apply: function(c){ return "a"; } },
          nft: { fragment: function(c){ return "chain x {}"; } },
          on_generate_post: function(cfg, ctx){ ran = true; },
        });
        reg.invoke_on_generate_post({}, {});
        print(sprintf("%J", {
          has_foo: type(reg.get_rpcd_methods().foo) === "function",
          lc_count: length(reg.get_lifecycle()),
          nf_count: length(reg.get_nft_fragments()),
          hook_ran: ran,
          listed: length(reg.get_all()),
        }));
      '
      rm -rf ${dir}
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.has_foo).toBe(false);
    expect(o.lc_count).toBe(0);
    expect(o.nf_count).toBe(0);
    expect(o.hook_ran).toBe(false);
    expect(o.listed).toBe(1);
  });

  it("discovery globs lib/plugins/*/init.uc and self-registers descriptors", async () => {
    // Stage a throwaway plugin dir next to the lib, then load it.
    const dir = "/tmp/plug_disc_uci";
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_fixture"
      trap 'rm -rf "$PLUG" ${dir}' EXIT
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_fixture", rpcd: { methods: { zz_ping: function(){ return "pong"; } } } });
return {};
EOF
      ${uciWith({ zz_fixture: true }, dir)}
      UCODE_APP_LIB_DIR="${LIB}" UCI_CONFIG_DIR=${dir} ucode -L '${LIB}' -e '
        let d = require("plugins.discovery");
        let n = d.load_all();
        let reg = require("plugins.registry");
        print(sprintf("%J", { loaded_at_least: n >= 1, has_zz: type(reg.get_rpcd_methods().zz_ping) === "function" }));
      '
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.loaded_at_least).toBe(true);
    expect(o.has_zz).toBe(true);
  });
});
