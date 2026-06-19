import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_status_detail.sh
// status_detail key presence, apk-stub cache perf, and parser parity (audit 13.2).

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
const INITD = `${WORK}/singbox-ui/root/etc/init.d/singbox-ui`;

// apk line the handler is expected to parse
const APK_LINE =
  "luci-singbox-ui-9.9.9-test noarch {luci-singbox-ui} (GPL-2.0-or-later) [installed]";

// Run status_detail with an apk stub installed into binDir and varlib isolated.
// Double-quote PATH so $PATH expands in shell (not single-quoted).
function runDetail(binDir: string, varlib: string): string {
  return `echo '{}' | PATH="${binDir}:$PATH" SINGBOX_VARLIB="${varlib}" ucode -L '${LIB}' '${HANDLER}' call status_detail 2>/dev/null`;
}

let TMPDIR = "";

describe("test_status_detail", () => {
  useGuest();

  beforeAll(async () => {
    const r = await exec("mktemp -d");
    TMPDIR = r.stdout.trim();
  });

  afterAll(async () => {
    if (TMPDIR) await exec(`rm -rf '${TMPDIR}'`);
  });

  it("status_detail is advertised in handler list", async () => {
    const r = await exec(`ucode -L '${LIB}' '${HANDLER}' list 2>/dev/null`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("status_detail");
  });

  it("status_detail returns all required keys", async () => {
    const r = await exec(
      `echo '{}' | ucode -L '${LIB}' '${HANDLER}' call status_detail 2>/dev/null`,
    );
    expect(r.exitCode).toBe(0);
    const out = JSON.parse(r.stdout) as Record<string, unknown>;
    for (const k of [
      "status",
      "running",
      "last_generate_ts",
      "last_generate_result",
      "last_apply_result",
      "last_apply_ts",
      "config_hash",
      "schema_version",
      "package_version",
      "service_start_ts",
      "now",
    ]) {
      expect(
        Object.hasOwn(out, k),
        `key '${k}' missing from status_detail`,
      ).toBe(true);
    }
  });

  it("S5-PERF: package_version cached — apk forked exactly once across two calls", async () => {
    const binDir = `${TMPDIR}/bin`;
    const varlib = `${TMPDIR}/varlib`;
    const counter = `${TMPDIR}/apk_calls`;

    // Install apk stub that counts invocations into counter file
    await exec(`
      mkdir -p '${binDir}' '${varlib}'
      : >'${counter}'
      cat >'${binDir}/apk' <<'STUBEOF'
#!/bin/sh
printf x >> '${counter}'
printf '%s\n' '${APK_LINE}'
STUBEOF
      chmod +x '${binDir}/apk'
    `);

    // First call: cache miss → apk runs
    const r1 = await exec(runDetail(binDir, varlib));
    expect(r1.exitCode).toBe(0);
    // Second call: cache hit → apk must NOT run again
    const r2 = await exec(runDetail(binDir, varlib));
    expect(r2.exitCode).toBe(0);

    const out1 = JSON.parse(r1.stdout) as Record<string, unknown>;
    const out2 = JSON.parse(r2.stdout) as Record<string, unknown>;
    expect(out1.package_version).toBe("9.9.9-test");
    expect(out2.package_version).toBe("9.9.9-test");

    // Cache file must exist after the first miss
    const cacheCheck = await exec(
      `[ -f '${varlib}/pkg_version' ] && echo YES || echo NO`,
    );
    expect(cacheCheck.stdout.trim()).toBe("YES");

    // Exactly one apk invocation across both calls
    const forksRaw = await exec(`wc -c < '${counter}' | tr -d ' '`);
    expect(forksRaw.stdout.trim()).toBe("1");
  });

  it("audit 13.2: init.d sed and rpcd pkg_version parsers are byte-identical", async () => {
    // Extract the live sed expression from init.d by having the guest do it.
    // The line contains: sed -n 's/^luci-singbox-ui-...
    const sedExtract = await exec(
      `grep -F "sed -n 's/^luci-singbox-ui" '${INITD}' | head -1 ` +
        `| sed -n "s/.*sed -n '\\([^']*\\)'.*/\\1/p"`,
    );
    expect(sedExtract.exitCode).toBe(0);
    const SED_EXPR = sedExtract.stdout.trim();
    expect(SED_EXPR.length).toBeGreaterThan(0);

    // Assert both parsers agree on a given fixture line
    const assertAgree = async (line: string, want: string) => {
      const binDir2 = `${TMPDIR}/bin2`;
      const varlib2 = `${TMPDIR}/varlib2`;
      await exec(
        `rm -rf '${binDir2}' '${varlib2}'; mkdir -p '${binDir2}' '${varlib2}'`,
      );

      // sed path (using the init.d-extracted expression)
      const sedOut = await exec(
        `printf '%s\\n' '${line}' | sed -n '${SED_EXPR}'`,
      );
      const sedVal = sedOut.stdout.trim();

      // rpcd ucode path: stub apk to emit exactly `line` (use putFile to avoid quoting hell)
      await putFile(`#!/bin/sh\nprintf '%s\\n' '${line}'\n`, `${binDir2}/apk`);
      await exec(`chmod +x '${binDir2}/apk'`);
      const rpcdOut = await exec(
        `echo '{}' | PATH="${binDir2}:$PATH" SINGBOX_VARLIB="${varlib2}" ` +
          `ucode -L '${LIB}' '${HANDLER}' call status_detail 2>/dev/null ` +
          `| ucode -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.package_version);'`,
      );
      const rpcdVal = rpcdOut.stdout.trim();

      expect(sedVal).toBe(rpcdVal);
      expect(sedVal).toBe(want);
    };

    // Normal multi-field apk line
    await assertAgree(APK_LINE, "9.9.9-test");
    // Edge: single-token line with no trailing space
    await assertAgree("luci-singbox-ui-1.2.3-r9", "1.2.3-r9");
  });
});
