import { beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// clash_delay builds /proxies/<name>/delay?url=...&timeout=... on the server,
// percent-encoding an arbitrary (unicode/space-bearing) proxy name and the test
// url, with a numeric timeout. The generic clash_path_ok allowlist rejects query
// strings, so this path is built+validated by call_clash_delay itself. We stub
// CLASH_CURL with a script that echoes the URL it was handed, so the handler's
// {status:"ok",body:<url>} lets us assert the exact constructed URL.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;

// curl stub path in guest
const STUB_DIR = `/tmp/clash_delay_${process.pid}`;
const CURL_STUB = `${STUB_DIR}/curl`;
const CURL_ARGV_STUB = `${STUB_DIR}/curl_argv`;

describe("test_clash_delay", () => {
  useGuest();

  beforeAll(async () => {
    // Set up stub dir and curl stubs in the guest
    await exec(`mkdir -p ${STUB_DIR}`);
    // curl stub: print the LAST argv element (clash_proxy puts the URL last)
    await putFile(
      `#!/bin/sh\nfor a in "$@"; do last="$a"; done\nprintf '%s' "$last"\n`,
      CURL_STUB,
    );
    await exec(`chmod +x ${CURL_STUB}`);
    // curl_argv stub: print the -m value
    await putFile(
      `#!/bin/sh\nprev=""; for a in "$@"; do [ "$prev" = "-m" ] && { printf '%s' "$a"; exit 0; }; prev="$a"; done\n`,
      CURL_ARGV_STUB,
    );
    await exec(`chmod +x ${CURL_ARGV_STUB}`);
  });

  // Helper: call the clash_delay RPC method via the handler
  async function call(
    jsonArgs: string,
  ): Promise<{ status: string; body: string }> {
    const r = await exec(
      `printf '%s' ${JSON.stringify(jsonArgs)} | env CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET="" ucode -L ${LIB} ${HANDLER} call clash_delay 2>/dev/null`,
    );
    try {
      return JSON.parse(r.stdout) as { status: string; body: string };
    } catch {
      return { status: "", body: r.stdout };
    }
  }

  // Helper: call with argv stub to read the -m value
  async function callM(jsonArgs: string): Promise<number> {
    const r = await exec(
      `printf '%s' ${JSON.stringify(jsonArgs)} | env CLASH_CURL=${CURL_ARGV_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET="" ucode -L ${LIB} ${HANDLER} call clash_delay 2>/dev/null | ucode -e 'let fs=require("fs");let d=json(fs.stdin.read("all")||"{}");print(d.body ?? "");'`,
    );
    return Number(r.stdout.trim());
  }

  it("clash_delay advertised in handler list", async () => {
    const r = await exec(`ucode -L ${LIB} ${HANDLER} list 2>/dev/null`);
    expect(r.stdout).toContain("clash_delay");
  });

  it("1) unicode + space name → correct percent-encoded URL", async () => {
    const result = await call('{"name":"🇺🇸 US-1"}');
    const want =
      "http://127.0.0.1:9090/proxies/%F0%9F%87%BA%F0%9F%87%B8%20US-1/delay?url=http%3A%2F%2Fwww.gstatic.com%2Fgenerate_204&timeout=5000";
    expect(result.body).toBe(want);
  });

  it("2) custom timeout is honored", async () => {
    const result = await call('{"name":"a","timeout":"3000"}');
    expect(result.body).toContain("&timeout=3000");
  });

  it("3) out-of-range / non-numeric timeout falls back to 5000", async () => {
    const result = await call('{"name":"a","timeout":"abc"}');
    expect(result.body).toContain("&timeout=5000");
  });

  it("4) invalid url scheme rejected", async () => {
    const result = await call('{"name":"a","url":"ftp://evil/x"}');
    expect(result.status).toBe("error");
  });

  it("5) empty name rejected", async () => {
    const result = await call('{"name":""}');
    expect(result.status).toBe("error");
  });

  it("6) CR/LF in name are dropped (no header/curl injection)", async () => {
    const result = await call('{"name":"a\\r\\nX"}');
    expect(result.status).toBe("ok");
    expect(result.body).not.toContain("%0D%0A");
  });

  it("RPC-1: default 5000ms probe → curl -m >= 5", async () => {
    const m = await callM('{"name":"a"}');
    expect(m).toBeGreaterThanOrEqual(5);
  });

  it("RPC-1: 10000ms probe → curl -m > 5 and covers the deadline", async () => {
    const m = await callM('{"name":"a","timeout":"10000"}');
    expect(m).toBeGreaterThan(5);
    expect(m).toBeGreaterThanOrEqual(12);
  });

  it("RPC-1: 60000ms probe → curl -m clamped to <= 65", async () => {
    const m = await callM('{"name":"a","timeout":"60000"}');
    expect(m).toBeLessThanOrEqual(65);
  });
});
