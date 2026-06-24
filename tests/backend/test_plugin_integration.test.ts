import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

describe("test_plugin_integration", () => {
  useGuest();

  it("a staged fixture plugin is discovered end-to-end", async () => {
    const r = await exec(`
      set -e
      SRC="${WORK}/tests/fixtures/plugins/fixture_plugin"
      DST="${LIB}/plugins/fixture_plugin"
      mkdir -p "$DST"; cp "$SRC"/*.uc "$DST"/
      rm -f /tmp/fixture_applied /tmp/fixture_torndown

      in_list=$(UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' list | ucode -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print((d.fixture_ping!=null && d.plugins!=null)?"yes":"no");')
      ping=$(echo '{}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call fixture_ping)
      plist=$(echo '{}' | UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${HANDLER}' call plugins)
      UCODE_APP_LIB_DIR='${LIB}' ucode -L '${LIB}' '${LIB}/../apply-plugins.uc' apply

      applied=$([ -f /tmp/fixture_applied ] && echo 1 || echo 0)
      rm -rf "$DST"
      rm -f /tmp/fixture_applied /tmp/fixture_torndown
      echo "{\\"in_list\\":\\"$in_list\\",\\"ping\\":$ping,\\"applied\\":$applied,\\"plist\\":$plist}"
    `);
    expect(r.exitCode).toBe(0);
    const o = JSON.parse(r.stdout);
    expect(o.in_list).toBe("yes");
    expect(o.ping.pong).toBe(true);
    expect(o.applied).toBe(1);
    expect(o.plist.plugins.some((p: any) => p.name === "fixture_plugin")).toBe(true);
  });
});
