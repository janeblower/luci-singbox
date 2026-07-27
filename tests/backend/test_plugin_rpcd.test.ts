import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

describe("test_plugin_rpcd", () => {
  useGuest();

  it("plugins method lists installed plugins with enabled + frontend_module", async () => {
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_list"
      trap 'rm -rf "$PLUG"' EXIT
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_list", version: "2" });
return {};
EOF
      out=$(echo '{}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugins)
      echo "$out"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.status).toBe("ok");
    const p = o.plugins.find((x: any) => x.name === "zz_list");
    expect(p).toBeTruthy();
    expect(p.version).toBe("2");
    expect(p.frontend_module).toBe("view.singbox-ui.plugins.zz_list.tab");
    expect(typeof p.enabled).toBe("boolean");
  });

  it("handler list + call surface a plugin-registered method", async () => {
    const r = await exec(`
      set -e
      PLUG="${LIB}/plugins/zz_rpcd"
      D=/tmp/plrpcd-$$
      trap 'rm -rf "$PLUG" "$D"' EXIT
      mkdir -p "$PLUG" "$D/uci"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_rpcd",
  rpcd: { methods: { zz_echo: function(){ printf("%J\\n", { status: "ok", who: "zz" }); } },
          acl_read: ["zz_echo"], acl_write: [] } });
return {};
EOF
      # A plugin's rpcd methods are only surfaced while the plugin is enabled.
      printf "config singbox-ui 'plugins'\n\toption zz_rpcd_enabled '1'\n" > "$D/uci/singbox-ui"
      list_has=$(UCI_CONFIG_DIR="$D/uci" UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' list | ucode -e 'let fs=require("fs"); let d=json(fs.stdin.read("all")||"{}"); print(d.zz_echo != null ? "yes" : "no");')
      call_out=$(echo '{}' | UCI_CONFIG_DIR="$D/uci" UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call zz_echo)
      print(){ :; }
      echo "{\\"list_has\\":\\"$list_has\\",\\"call_out\\":$call_out}"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.list_has).toBe("yes");
    expect(o.call_out.status).toBe("ok");
    expect(o.call_out.who).toBe("zz");
  });

  it("plugin_enable toggles the UCI flag; plugin_install shells apk (mocked)", async () => {
    const r = await exec(`
      set -e
      # Ensure the singbox-ui UCI config exists in the system location.
      # The test VM does not have singbox-ui installed; copy the working-tree
      # default config so uci can read/write it.
      if [ ! -f /etc/config/singbox-ui ]; then
        cp '${WORK}/singbox-ui/root/etc/config/singbox-ui' /etc/config/singbox-ui
      fi

      # mock apk: record args, succeed
      MOCK=/tmp/zz_apk_called; rm -f "$MOCK"
      cat > /tmp/zz_apk <<'EOF'
#!/bin/sh
echo "$@" > /tmp/zz_apk_called
exit 0
EOF
      chmod +x /tmp/zz_apk

      echo '{"name":"zz_en","enabled":true}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugin_enable >/dev/null
      flag=$(uci -q get singbox-ui.plugins.zz_en_enabled || echo MISSING)

      echo '{"package":"singbox-ui-plugin-x"}' | APK_CMD=/tmp/zz_apk UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugin_install >/dev/null
      args=$(cat /tmp/zz_apk_called 2>/dev/null || echo NONE)

      uci -q delete singbox-ui.plugins.zz_en_enabled || true; uci -q commit singbox-ui || true
      echo "{\\"flag\\":\\"$flag\\",\\"args\\":\\"$args\\"}"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.flag).toBe("1");
    expect(o.args).toContain("add");
    expect(o.args).toContain("singbox-ui-plugin-x");
  });

  // #9 again, at a different door. cursor.commit() flushes the WHOLE singbox-ui
  // package, so enabling a plugin while someone has a LuCI edit staged (Save
  // without Apply) used to commit THEIR work into /etc/config with no Apply —
  // and Revert then had nothing left to revert.
  it("plugin_enable refuses while another change is staged", async () => {
    const r = await exec(`
      if [ ! -f /etc/config/singbox-ui ]; then
        cp '${WORK}/singbox-ui/root/etc/config/singbox-ui' /etc/config/singbox-ui
      fi
      uci -q revert singbox-ui || true
      uci -q set singbox-ui.zz_staged=ruleset     # staged, NOT committed

      echo '{"name":"zz_guard","enabled":true}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugin_enable > /tmp/zz_guard.json

      flag=$(uci -q get singbox-ui.plugins.zz_guard_enabled || echo MISSING)
      still=$(uci -q changes singbox-ui | grep -c zz_staged || true)
      uci -q revert singbox-ui || true
      printf '{"out":%s,"flag":"%s","still":"%s"}' "$(cat /tmp/zz_guard.json)" "$flag" "$still"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.out.status).toBe("error");
    expect(o.flag).toBe("MISSING"); // nothing written
    expect(o.still).toBe("1"); // the staged edit is untouched
  });

  it("the plugin package prefix matches what the feed actually builds", async () => {
    // PLUGIN_PKG_PREFIX said "luci-app-singbox-plugin-", a name no package in
    // this repo has ever had, so every Install click was rejected before apk.
    const r = await exec(
      `echo '{"package":"singbox-ui-plugin-awg_warp"}' | APK_CMD=/bin/true UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugin_install`,
    );
    expect(JSON.parse(r.stdout).status).toBe("ok");
  });
});
