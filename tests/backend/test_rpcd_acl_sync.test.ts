import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Port of tests/backend/test_rpcd_acl_sync.sh
// Single-source guard: handler `list` keys MUST equal ACL read∪write.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

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
        let dir = "${WORK}/luci-app-singbox-ui/root/usr/share/rpcd/acl.d";
        let files = fs.glob(dir + "/*.json") ?? [];
        let s = [];
        for (let f in files) {
          let d = json(fs.readfile(f) || "{}");
          for (let role, obj in d) {
            let r = (((obj.read ?? {}).ubus ?? {})["singbox-ui"] ?? []);
            let w = (((obj.write ?? {}).ubus ?? {})["singbox-ui"] ?? []);
            for (let k in r) push(s, k);
            for (let k in w) push(s, k);
          }
        }
        // de-dup
        let seen = {}, out = [];
        for (let k in s) if (!seen[k]) { seen[k] = true; push(out, k); }
        print(join("\\n", sort(out)) + "\\n");
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
