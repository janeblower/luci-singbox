import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// kTLS (sing-box 1.13+): tls_kernel_tx / tls_kernel_rx emit kernel_tx/kernel_rx
// on both sides, and the kmod-tls dependency the fields declare (`requires_pkg`)
// is probed/installed through the pkg_status + pkg_install rpcd methods, whose
// package allowlist IS their input validation (apk runs as root).

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

describe("kTLS TLS fields", () => {
  useGuest();

  it("outbound: kernel_tx/kernel_rx emitted", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"outbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", tls_enabled:"1", tls_kernel_tx:"1", tls_kernel_rx:"1" }
      );
      print(sprintf("%s|%s", got.tls.kernel_tx, got.tls.kernel_rx));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|true");
  });

  it("inbound: kernel_tx emitted, kernel_rx omitted when off", async () => {
    const src = `
      let f = require("builder._filler");
      let got = f.build(
        { kind:"inbound", sing_box_type:"x", fields:[], shared:{ tls:{} } },
        { ".name":"t", listen_port:"443", tls_enabled:"1", tls_kernel_tx:"1", tls_kernel_rx:"0" }
      );
      print(sprintf("%s|%s", got.tls.kernel_tx, got.tls.kernel_rx == null ? "ABSENT" : "PRESENT"));
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true|ABSENT");
  });

  it("fields declare requires_pkg=kmod-tls in the schema dump", async () => {
    // dump_all() does not eager-load the protocol descriptors (outbound.uc does,
    // on the prod path) — require one, or d.outbound comes back empty.
    const src = `
      require("builder.protocols.vless");
      let d = require("builder.protocols.schema_dump").dump_all();
      let found = "";
      for (let f in d.outbound.vless.fields)
        if (f.name == "tls_kernel_tx" && f.requires_pkg) found = f.requires_pkg;
      print(found);
    `;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("kmod-tls");
  });
});

describe("pkg_status / pkg_install rpcd methods", () => {
  useGuest();

  it("pkg_status reports installed / not installed via apk", async () => {
    const r = await exec(`
      cat > /tmp/fake_apk <<'APK'
#!/bin/sh
# list --installed <pkg>: print a line only for kmod-tls
[ "$1" = "list" ] && [ "$3" = "kmod-tls" ] && [ -f /tmp/ktls_present ] && \
  echo "kmod-tls-6.6.1-r1 noarch {kmod-tls} (GPL-2.0) [installed]"
exit 0
APK
      chmod +x /tmp/fake_apk

      rm -f /tmp/ktls_present
      echo '{"package":"kmod-tls"}' | APK_CMD=/tmp/fake_apk \
        ucode -L "${LIB}" "${HANDLER}" call pkg_status

      touch /tmp/ktls_present
      echo '{"package":"kmod-tls"}' | APK_CMD=/tmp/fake_apk \
        ucode -L "${LIB}" "${HANDLER}" call pkg_status
      rm -f /tmp/ktls_present /tmp/fake_apk
    `);
    const lines = r.stdout.trim().split("\n");
    expect(JSON.parse(lines[0]).installed).toBe(false);
    expect(JSON.parse(lines[1]).installed).toBe(true);
  });

  it("pkg_install runs `apk add` for an allowlisted package", async () => {
    const r = await exec(`
      cat > /tmp/fake_apk <<'APK'
#!/bin/sh
echo "$@" > /tmp/apk_args
exit 0
APK
      chmod +x /tmp/fake_apk
      echo '{"package":"kmod-tls"}' | APK_CMD=/tmp/fake_apk \
        ucode -L "${LIB}" "${HANDLER}" call pkg_install
      echo "args=$(cat /tmp/apk_args)"
      rm -f /tmp/apk_args /tmp/fake_apk
    `);
    expect(r.stdout).toContain('"status": "ok"');
    expect(r.stdout).toContain("args=add -- kmod-tls");
  });

  it("rejects any package outside the allowlist (never reaches apk)", async () => {
    const r = await exec(`
      cat > /tmp/fake_apk <<'APK'
#!/bin/sh
echo "$@" > /tmp/apk_args
exit 0
APK
      chmod +x /tmp/fake_apk
      rm -f /tmp/apk_args
      for p in '--initdb' 'busybox' 'kmod-tls; rm -rf /tmp/nope' ''; do
        printf '{"package":"%s"}' "$p" | APK_CMD=/tmp/fake_apk \
          ucode -L "${LIB}" "${HANDLER}" call pkg_install
      done
      echo "apk_ran=$(test -f /tmp/apk_args && echo yes || echo no)"
      rm -f /tmp/fake_apk
    `);
    expect(r.stdout).not.toContain('"status": "ok"');
    expect(r.stdout).toContain("apk_ran=no");
  });
});
