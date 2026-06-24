import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Tests for the awg_warp plugin init.uc: self-provision (awg_install) and
// plugin-ACL guard (plugin acl.d matches init.uc register() declaration).

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
// Plugin source tree (unified lib/ path — result of prior refactor).
const PLUGIN_SRC = `${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/singbox-ui/lib/plugins/awg_warp`;
const PLUGIN_ACL_SRC = `${WORK}/luci-app-singbox-plugin-awg-warp/root/usr/share/rpcd/acl.d/luci-singbox-plugin-awg-warp.json`;

describe("awg_install", () => {
  useGuest();

  it("adds the awg feed key+repo and apk-adds kmod-amneziawg", async () => {
    // Stage the plugin into ${LIB}/plugins/ so discovery picks up init.uc.
    // EXIT trap removes it so the plugin is never left staged; test_rpcd_acl_sync
    // runs with no plugin in ${LIB}/plugins/ → handler list = core only → PASS.
    const r = await exec(`
      set -e
      cleanup() {
        rm -rf "${LIB}/plugins/awg_warp"
      }
      trap cleanup EXIT

      cp -r "${PLUGIN_SRC}" "${LIB}/plugins/awg_warp"

      # Stub apk: records all invocations.
      cat > /tmp/m_apk <<'STUB'
#!/bin/sh
echo "$@" >> /tmp/m_apk_log
exit 0
STUB
      chmod +x /tmp/m_apk
      rm -f /tmp/m_apk_log

      mkdir -p /tmp/apk_keys
      : > /tmp/apk_repos

      out=$(echo '{}' | \
        APK_CMD=/tmp/m_apk \
        SB_APK_KEYS=/tmp/apk_keys \
        SB_APK_REPOS=/tmp/apk_repos \
        SB_AWG_FEED_KEY="${LIB}/plugins/awg_warp/awg-openwrt-feed.pem" \
        UCODE_APP_LIB_DIR="${LIB}" \
        ucode -L "${LIB}" "${HANDLER}" call awg_install)

      keyc=$(ls /tmp/apk_keys | wc -l)
      hask=$(grep -c "kmod-amneziawg" /tmp/m_apk_log 2>/dev/null || true)
      hasr=$(grep -c "slava-shchipunov" /tmp/apk_repos 2>/dev/null || true)

      printf '%s\\n' "$out"
      echo "keyc=$keyc hask=$hask hasr=$hasr"
    `);
    expect(r.exitCode).toBe(0);

    // Parse the rpcd JSON response (first JSON object line).
    const firstLine = r.stdout
      .split("\n")
      .find((l) => l.trim().startsWith("{"));
    expect(firstLine).toBeTruthy();
    const o = JSON.parse(firstLine ?? "{}");
    expect(o.status).toBe("ok");

    // Parse the summary line.
    const summary = r.stdout.split("\n").find((l) => l.includes("keyc="));
    expect(summary).toBeTruthy();
    const keyc = parseInt(summary?.match(/keyc=(\d+)/)?.[1] ?? "0", 10);
    const hask = parseInt(summary?.match(/hask=(\d+)/)?.[1] ?? "0", 10);
    const hasr = parseInt(summary?.match(/hasr=(\d+)/)?.[1] ?? "0", 10);

    // Feed key was copied into the (mock) keys dir.
    expect(keyc).toBeGreaterThan(0);
    // apk add was invoked with kmod-amneziawg.
    expect(hask).toBeGreaterThan(0);
    // Repo line containing the awg feed URL was written.
    expect(hasr).toBeGreaterThan(0);
  });

  it("rejects malicious board target with newline injection, falls back to x86/64", async () => {
    // Regression: board.release.target containing a newline + injected repo line
    // must NOT reach /etc/apk/repositories.  The sanitizer should reject the value
    // and fall back to "x86/64", so only the legitimate slava-shchipunov line appears.
    const r = await exec(`
      set -e
      cleanup() {
        rm -rf "${LIB}/plugins/awg_warp"
        rm -f /tmp/m_apk2 /tmp/m_apk2_log /tmp/board_stub2 /tmp/apk_repos2
      }
      trap cleanup EXIT

      cp -r "${PLUGIN_SRC}" "${LIB}/plugins/awg_warp"

      # Stub apk: silent success.
      cat > /tmp/m_apk2 <<'STUB'
#!/bin/sh
echo "$@" >> /tmp/m_apk2_log
exit 0
STUB
      chmod +x /tmp/m_apk2

      # Board stub: returns a MALICIOUS target with an embedded newline + injected line.
      cat > /tmp/board_stub2 <<'BOARDSTUB'
#!/bin/sh
printf '{"release":{"target":"x86/64\\nhttps://evil.example/malicious.adb evil"}}'
BOARDSTUB
      chmod +x /tmp/board_stub2

      mkdir -p /tmp/apk_keys2
      : > /tmp/apk_repos2

      out=$(echo '{}' | \
        APK_CMD=/tmp/m_apk2 \
        SB_APK_KEYS=/tmp/apk_keys2 \
        SB_APK_REPOS=/tmp/apk_repos2 \
        SB_AWG_FEED_KEY="${LIB}/plugins/awg_warp/awg-openwrt-feed.pem" \
        SB_UBUS_BOARD=/tmp/board_stub2 \
        UCODE_APP_LIB_DIR="${LIB}" \
        ucode -L "${LIB}" "${HANDLER}" call awg_install)

      hasevil=$(grep -c "evil.example" /tmp/apk_repos2 2>/dev/null || true)
      hasgood=$(grep -c "slava-shchipunov" /tmp/apk_repos2 2>/dev/null || true)

      printf '%s\\n' "$out"
      echo "hasevil=$hasevil hasgood=$hasgood"
    `);
    expect(r.exitCode).toBe(0);

    // rpcd response must be ok (install succeeded with fallback target).
    const firstLine = r.stdout
      .split("\n")
      .find((l) => l.trim().startsWith("{"));
    expect(firstLine).toBeTruthy();
    const o = JSON.parse(firstLine ?? "{}");
    expect(o.status).toBe("ok");

    // Parse the summary line.
    const summary = r.stdout.split("\n").find((l) => l.includes("hasevil="));
    expect(summary).toBeTruthy();
    const hasevil = parseInt(summary?.match(/hasevil=(\d+)/)?.[1] ?? "1", 10);
    const hasgood = parseInt(summary?.match(/hasgood=(\d+)/)?.[1] ?? "0", 10);

    // The malicious line must NOT appear in the repos file.
    expect(hasevil).toBe(0);
    // The legitimate feed URL (fallback x86/64) IS written.
    expect(hasgood).toBeGreaterThan(0);
  });
});

describe("plugin ACL guard", () => {
  useGuest();

  it("plugin acl.d read∪write set matches init.uc register() declaration", async () => {
    // Read the plugin's own acl.d file directly (no staging needed).
    // Asserts exact match: read={awg_status}, write={warp_register,awg_install,awg_generate}.
    const r = await exec(`
      set -e
      ucode -e '
        let fs = require("fs");
        let f = "${PLUGIN_ACL_SRC}";
        let d = json(fs.readfile(f) || "{}");
        let entry = d["luci-singbox-plugin-awg-warp"] ?? {};
        let read_arr  = ((entry.read  ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let write_arr = ((entry.write ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let all = [];
        for (let m in read_arr)  push(all, m);
        for (let m in write_arr) push(all, m);
        let seen = {}, out = [];
        for (let m in all) if (!seen[m]) { seen[m] = true; push(out, m); }
        sort(out);
        printf("%J\\n", { read: read_arr, write: write_arr, all: out });
      '
    `);
    expect(r.exitCode).toBe(0);
    const { read, write, all } = JSON.parse(r.stdout) as {
      read: string[];
      write: string[];
      all: string[];
    };

    // Exact match with what init.uc passes to reg.register().
    expect([...read].sort()).toEqual(["awg_status"]);
    expect([...write].sort()).toEqual([
      "awg_generate",
      "awg_install",
      "warp_register",
    ]);
    // No overlap between read and write.
    for (const m of read) {
      expect(write.includes(m)).toBe(false);
    }
    // All 4 methods present.
    expect(all.length).toBe(4);
  });
});
