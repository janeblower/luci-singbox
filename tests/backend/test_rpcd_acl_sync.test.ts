import { describe, it, expect } from "bun:test";
import { exec } from "../helpers/ssh.ts";
import { useGuest } from "../helpers/guest.ts";

// Port of tests/backend/test_rpcd_acl_sync.sh
// Single-source guard: handler `list` keys MUST equal ACL read∪write.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ??
  "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER =
  `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
const ACL =
  `${WORK}/luci-app-singbox-ui/root/usr/share/rpcd/acl.d/luci-singbox-ui.json`;

describe("test_rpcd_acl_sync", () => {
  useGuest();

  it("handler method set matches ACL read∪write", async () => {
    // Get methods advertised by handler via its list output
    const r = await exec(`
      set -e
      handler_methods=$(ucode -L '${LIB}' '${HANDLER}' list 2>/dev/null \
        | ucode -e '
          let fs = require("fs");
          let d = json(fs.stdin.read("all") || "{}");
          let s = []; for (let k in d) push(s, k);
          print(join("\\n", sort(s)) + "\\n");
        ')

      acl_methods=$(ucode -e '
        let fs = require("fs");
        let d = json(fs.readfile("${ACL}") || "{}");
        let o = d["luci-singbox-ui"] ?? {};
        let s = [];
        for (let k in (o.read.ubus["singbox-ui"] ?? []))  push(s, k);
        for (let k in (o.write.ubus["singbox-ui"] ?? [])) push(s, k);
        print(join("\\n", sort(s)) + "\\n");
      ')

      if [ "$handler_methods" != "$acl_methods" ]; then
        echo "MISMATCH"
        echo "handler: $handler_methods"
        echo "acl: $acl_methods"
        exit 1
      fi
      echo "MATCH"
    `);

    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("MATCH");
  });
});
