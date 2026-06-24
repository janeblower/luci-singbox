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
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_list", version: "2" });
return {};
EOF
      out=$(echo '{}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugins)
      rm -rf "$PLUG"
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
      mkdir -p "$PLUG"
      cat > "$PLUG/init.uc" <<'EOF'
let reg = require("plugins.registry");
reg.register({ name: "zz_rpcd",
  rpcd: { methods: { zz_echo: function(){ printf("%J\\n", { status: "ok", who: "zz" }); } },
          acl_read: ["zz_echo"], acl_write: [] } });
return {};
EOF
      list_has=$(UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' list | ucode -e 'let fs=require("fs"); let d=json(fs.stdin.read("all")||"{}"); print(d.zz_echo != null ? "yes" : "no");')
      call_out=$(echo '{}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call zz_echo)
      rm -rf "$PLUG"
      print(){ :; }
      echo "{\\"list_has\\":\\"$list_has\\",\\"call_out\\":$call_out}"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.list_has).toBe("yes");
    expect(o.call_out.status).toBe("ok");
    expect(o.call_out.who).toBe("zz");
  });
});
