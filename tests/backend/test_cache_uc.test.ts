import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";
import { runUcode } from "../helpers/ucode.ts";

// Tests lib/cache.uc storage modes via a tiny ucode wrapper that hand-feeds
// singbox-ui sections via uci.cursor. Mirrors the harness in test_dns_uc.sh.

describe("test_cache_uc", () => {
  useGuest();

  // Helper: write a UCI config file in the guest and call cache.build_cache
  // via uci.cursor, returning the parsed JSON result.
  async function runCase(
    label: string,
    uciConfig: string,
  ): Promise<Record<string, unknown>> {
    const cfgDir = `/tmp/cache_uc_${process.pid}_${label}`;
    // Create config dir and write singbox-ui config
    await exec(`mkdir -p ${cfgDir}`);
    await putFile(uciConfig, `${cfgDir}/singbox-ui`);
    const src = `
let uci = require("uci");
let cache = require("cache");
let cur = uci.cursor(${JSON.stringify(cfgDir)});
let out = cache.build_cache(cur);
printf("%J\\n", out);
`;
    const r = await runUcode(src);
    // Cleanup
    await exec(`rm -rf ${cfgDir}`);
    if (r.exitCode !== 0) {
      throw new Error(`ucode exit ${r.exitCode}: ${r.stderr}\n${r.stdout}`);
    }
    return JSON.parse(r.stdout) as Record<string, unknown>;
  }

  it("ram storage → /tmp/singbox-ui-cache.db", async () => {
    const out = await runCase(
      "ram",
      "config cache 'cache'\n    option enabled '1'\n    option storage 'ram'\n",
    );
    expect(out.path).toBe("/tmp/singbox-ui-cache.db");
    expect("store_fakeip" in out).toBe(false);
  });

  it("flash storage → /etc/sing-box/cache.db", async () => {
    const out = await runCase(
      "flash",
      "config cache 'cache'\n    option enabled '1'\n    option storage 'flash'\n",
    );
    expect(out.path).toBe("/etc/sing-box/cache.db");
    expect("store_fakeip" in out).toBe(false);
  });

  it("custom storage → uses option path", async () => {
    const out = await runCase(
      "custom",
      "config cache 'cache'\n    option enabled '1'\n    option storage 'custom'\n    option path '/srv/cache.db'\n",
    );
    expect(out.path).toBe("/srv/cache.db");
    expect("store_fakeip" in out).toBe(false);
  });

  it("no storage option → defaults to ram path", async () => {
    const out = await runCase(
      "blank",
      "config cache 'cache'\n    option enabled '1'\n",
    );
    expect(out.path).toBe("/tmp/singbox-ui-cache.db");
    expect("store_fakeip" in out).toBe(false);
  });

  it("store_fakeip with enabled fakeip dns_server → emitted", async () => {
    const out = await runCase(
      "fakeip",
      `config cache 'cache'
    option enabled '1'
    option storage 'ram'
    option store_fakeip '1'

config dns_server 'fakeip'
    option enabled '1'
    option type 'fakeip'
`,
    );
    expect(out.path).toBe("/tmp/singbox-ui-cache.db");
    expect(out.store_fakeip).toBe(true);
  });

  it("store_fakeip without fakeip dns_server → not emitted", async () => {
    const out = await runCase(
      "nofakeip",
      "config cache 'cache'\n    option enabled '1'\n    option storage 'ram'\n    option store_fakeip '1'\n",
    );
    expect(out.path).toBe("/tmp/singbox-ui-cache.db");
    expect("store_fakeip" in out).toBe(false);
  });

  it("cache_db_path: enabled ram → /tmp path, disabled → null", async () => {
    // Test cache_db_path directly via a ucode snippet
    const src = `
let uci = require("uci");
let cache = require("cache");

let cfgDir = "/tmp/cache_uc_dbpath_${process.pid}";
let fs = require("fs");
fs.mkdir(cfgDir);

// enabled ram
fs.writefile(cfgDir + "/singbox-ui", "config cache 'cache'\\n\\toption enabled '1'\\n\\toption storage 'ram'\\n");
let cur = uci.cursor(cfgDir);
let p = cache.cache_db_path(cur);
if (p != "/tmp/singbox-ui-cache.db") { print("FAIL enabled: " + p + "\\n"); exit(1); }

// disabled
fs.writefile(cfgDir + "/singbox-ui", "config cache 'cache'\\n\\toption enabled '0'\\n");
cur = uci.cursor(cfgDir);
p = cache.cache_db_path(cur);
if (p != null) { print("FAIL disabled: " + p + "\\n"); exit(1); }

// flash
fs.writefile(cfgDir + "/singbox-ui", "config cache 'cache'\\n\\toption enabled '1'\\n\\toption storage 'flash'\\n");
cur = uci.cursor(cfgDir);
p = cache.cache_db_path(cur);
if (p != "/etc/sing-box/cache.db") { print("FAIL flash: " + p + "\\n"); exit(1); }

// cleanup
system("rm -rf " + cfgDir);
print("OK\\n");
`;
    const r = await runUcode(src);
    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("OK");
  });
});
