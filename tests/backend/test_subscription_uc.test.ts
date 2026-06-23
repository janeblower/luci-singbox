import { describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SHARE = "/tmp/work/singbox-ui/root/usr/share/singbox-ui";

// Host-side paths (tests run on the Docker host, repo mounted at /work)
const HOST_SHARE = join(
  import.meta.dir,
  "../../singbox-ui/root/usr/share/singbox-ui",
);
const SUB_UC = `${SHARE}/subscription.uc`;

// Run subscription.uc CLI with given args and env overrides.
// Returns exec result.
async function _runSub(
  args: string[],
  env: Record<string, string>,
  stdinData?: string,
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const envStr = Object.entries(env)
    .map(([k, v]) => `${k}=${v}`)
    .join(" ");
  const argStr = args.map((a) => `'${a.replace(/'/g, "'\\''")}'`).join(" ");
  const cmd = `cd /tmp/work && env ${envStr} ucode -L ${LIB} ${SUB_UC} ${argStr}`;
  if (stdinData !== undefined) {
    // pass stdin via process substitution workaround
    const tmpIn = `/tmp/sb-sub-in-${Date.now()}`;
    await putFile(stdinData, tmpIn);
    return exec(`${cmd} <${tmpIn}; rc=$?; rm -f ${tmpIn}; exit $rc`);
  }
  return exec(cmd);
}

// Build a unique temp dir prefix per test
let counter = 0;
function tmpDir() {
  return `/tmp/sbuct-${Date.now()}-${counter++}`;
}

// UCI config for a single subscription outbound
function uciSub(name: string, opts: Record<string, string> = {}): string {
  const extra = Object.entries(opts)
    .map(([k, v]) => `\toption ${k} '${v}'`)
    .join("\n");
  return `config outbound '${name}'\n\toption type 'subscription'\n${extra ? `${extra}\n` : ""}`;
}

// Curl stub that reads FAKE_BODY_FILE and writes to -o arg, writes headers to -D arg
const CURL_STUB = `#!/bin/sh
echo "$@" >>"\${FAKE_CURL_LOG:-/dev/null}"
out=""; hdr=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; esac
  prev="$a"
done
[ -n "$hdr" ] && printf 'HTTP/1.1 200 OK\\r\\nserver: stub\\r\\n\\r\\n' >"$hdr"
rc="\${FAKE_CURL_RC:-0}"
if [ "$rc" = "0" ] && [ -n "$out" ]; then cat "\${FAKE_BODY_FILE:-/dev/null}" >"$out"; fi
exit "$rc"
`;

describe("test_subscription_uc", () => {
  useGuest();

  it("foreach(null) yields all sections", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}`);
    await putFile(
      `config outbound 'a'\n\toption type 'subscription'\nconfig outbound 'b'\n\toption type 'interface'\n`,
      `${dir}/singbox-ui`,
    );
    // Use inline probe
    const probeContent = `
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
let n = 0;
uci.foreach("singbox-ui", null, function (s) { n++; });
print(n);
`;
    const tmpUc = `/tmp/sbprobe-${Date.now()}.uc`;
    await putFile(probeContent, tmpUc);
    const r = await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} ucode -L ${LIB} ${tmpUc}; rm -f ${tmpUc}`,
    );
    expect(r.stdout.trim()).toBe("2");
    await exec(`rm -rf ${dir}`);
  });

  it("fetch-subs decodes base64 body and writes sub_<name>.txt", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // base64("vless://uuid@host:443?security=tls#A\n")
    await putFile(
      "dmxlc3M6Ly91dWlkQGhvc3Q6NDQzP3NlY3VyaXR5PXRscyNBCg==",
      `${dir}/body`,
    );
    await putFile(
      uciSub("subA", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    const _r = await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `cat ${dir}/runtime/sub_subA.txt 2>/dev/null || echo MISSING`,
    );
    expect(check.stdout).toMatch(/^vless:\/\/uuid@host:443/);
    await exec(`rm -rf ${dir}`);
  });

  it("fetch-subs decodes base64 body of a tuic-only sub (regression: PROXY_SCHEME_RE must cover every parse_proxy_url scheme)", async () => {
    // tuic/hysteria/hy/anytls/socks were dispatched by parse_proxy_url but were
    // missing from the decode-trigger whitelist (PROXY_SCHEME_RE), so a base64
    // subscription composed only of them never decoded and was rejected with
    // "no valid proxy URL in response".
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // base64("tuic://11111111-1111-1111-1111-111111111111:pass@host.test:443#NodeT\n")
    await putFile(
      "dHVpYzovLzExMTExMTExLTExMTEtMTExMS0xMTExLTExMTExMTExMTExMTpwYXNzQGhvc3QudGVzdDo0NDMjTm9kZVQK",
      `${dir}/body`,
    );
    await putFile(
      uciSub("subT", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `cat ${dir}/runtime/sub_subT.txt 2>/dev/null || echo MISSING`,
    );
    expect(check.stdout).toMatch(/^tuic:\/\/11111111-/);
    await exec(`rm -rf ${dir}`);
  });

  it("fetch-subs decodes a url-safe, unpadded base64 body (regression: tolerant b64 via helpers.b64_decode)", async () => {
    // The raw b64dec() builtin rejects the url-safe alphabet (-/_) and missing
    // padding; subscription used it directly, so url-safe subscriptions silently
    // failed. try_b64_decode now shares the tolerant helpers.b64_decode with the
    // share-link parser.
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // base64("vless://uuid@host.test:443?security=tls#A\n"), url-safe + unpadded
    await putFile(
      "dmxlc3M6Ly91dWlkQGhvc3QudGVzdDo0NDM_c2VjdXJpdHk9dGxzI0EK",
      `${dir}/body`,
    );
    await putFile(
      uciSub("subU", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `cat ${dir}/runtime/sub_subU.txt 2>/dev/null || echo MISSING`,
    );
    expect(check.stdout).toMatch(/^vless:\/\/uuid@host\.test:443/);
    await exec(`rm -rf ${dir}`);
  });

  it("fetch-subs accepts plain-text body when base64 decode produces no scheme", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("trojan://pwd@host:443#B\n", `${dir}/body`);
    await putFile(
      uciSub("subA", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `grep '^trojan://' ${dir}/runtime/sub_subA.txt 2>/dev/null || echo MISSING`,
    );
    expect(check.stdout).toContain("trojan://");
    await exec(`rm -rf ${dir}`);
  });

  it("SINGBOX_BOOT_FETCH=1 still fetches subs (boot path active)", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // b64("vless://uuid@host:443\n")
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    await putFile(
      uciSub("subA", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    const _r = await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log SINGBOX_BOOT_FETCH=1 CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `test -s ${dir}/runtime/sub_subA.txt && echo ok || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("ok");
    const curlLog = await exec(`cat ${dir}/curl.log 2>/dev/null || echo ""`);
    expect(curlLog.stdout).toContain("-A ");
    await exec(`rm -rf ${dir}`);
  });

  it("both subscriptions are fetched (sequential)", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    const uci =
      uciSub("subA", { sub_url: "https://example.test/a" }) +
      uciSub("subB", { sub_url: "https://example.test/b" });
    await putFile(uci, `${dir}/singbox-ui`);
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const a = await exec(
      `test -s ${dir}/runtime/sub_subA.txt && echo ok || echo MISSING`,
    );
    const b = await exec(
      `test -s ${dir}/runtime/sub_subB.txt && echo ok || echo MISSING`,
    );
    expect(a.stdout.trim()).toBe("ok");
    expect(b.stdout.trim()).toBe("ok");
    await exec(`rm -rf ${dir}`);
  });

  it("failed fetch does not clobber existing sub_<name>.txt", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("vless://kept@host:1\n", `${dir}/runtime/sub_subA.txt`);
    await putFile(
      uciSub("subA", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_CURL_RC=1 FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null || true`,
    );
    const check = await exec(
      `grep '^vless://kept@host:1' ${dir}/runtime/sub_subA.txt 2>/dev/null || echo MISSING`,
    );
    expect(check.stdout).toContain("vless://kept@host:1");
    await exec(`rm -rf ${dir}`);
  });

  it("refresh respects mtime: fresh is no-op, forced re-downloads", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    await putFile(
      `config outbound 'subA'\n\toption type 'subscription'\n\toption sub_url 'https://example.test/sub'\n\toption sub_interval '3600'\n`,
      `${dir}/singbox-ui`,
    );
    const baseEnv = `UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`;
    // warm cache
    await exec(
      `cd /tmp/work && env ${baseEnv} ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    // read mtime
    const mt1 = await exec(`stat -c %Y ${dir}/runtime/sub_subA.txt`);
    // sleep 1 second
    await exec("sleep 1");
    // clear log
    await exec(`> ${dir}/curl.log`);
    // fresh refresh (no-op)
    await exec(
      `cd /tmp/work && env ${baseEnv} SINGBOX_NO_RELOAD=1 ucode -L ${LIB} ${SUB_UC} refresh 2>/dev/null`,
    );
    const mt2 = await exec(`stat -c %Y ${dir}/runtime/sub_subA.txt`);
    expect(mt1.stdout.trim()).toBe(mt2.stdout.trim());
    const log1 = await exec(`cat ${dir}/curl.log`);
    expect(log1.stdout.trim()).toBe(""); // no curl call

    // forced refresh
    await exec(`> ${dir}/curl.log`);
    await exec(
      `cd /tmp/work && env ${baseEnv} SINGBOX_NO_RELOAD=1 ucode -L ${LIB} ${SUB_UC} refresh force 2>/dev/null`,
    );
    const log2 = await exec(`cat ${dir}/curl.log`);
    expect(log2.stdout.trim().length).toBeGreaterThan(0);
    await exec(`rm -rf ${dir}`);
  });

  it("sub_user_agent is passed to curl -A", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    await putFile(
      uciSub("subA", {
        sub_url: "https://example.test/sub",
        sub_user_agent: "v2raytun/1.0",
      }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const log = await exec(`cat ${dir}/curl.log`);
    expect(log.stdout).toContain("-A v2raytun/1.0");
    await exec(`rm -rf ${dir}`);
  });

  it("parse_ss: plain method:password@host:port#name", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound");
let url = ARGV[0];
let parsed = outbound.parse_proxy_url(url);
print(parsed == null ? "null" : sprintf("%J", parsed));
`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://aes-256-gcm:test-pw@s.example.com:8388#myname'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.type).toBe("shadowsocks");
    expect(obj.server).toBe("s.example.com");
    expect(obj.server_port).toBe(8388);
    expect(obj.method).toBe("aes-256-gcm");
    expect(obj.password).toBe("test-pw");
  });

  it("parse_ss: legacy base64 userinfo", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    // base64("aes-256-gcm:test-pw") = "YWVzLTI1Ni1nY206dGVzdC1wdw=="
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://YWVzLTI1Ni1nY206dGVzdC1wdw==@s.example.com:8388#myname'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.method).toBe("aes-256-gcm");
    expect(obj.password).toBe("test-pw");
  });

  it("parse_ss: full-body b64 strips NUL from password", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    // base64 of "aes-256-gcm:pa\x00ss@1.2.3.4:8443"
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://YWVzLTI1Ni1nY206cGEAc3NAMS4yLjMuNDo4NDQz'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.password).toBe("pass");
  });

  it("parse_ss: legacy b64 userinfo strips NUL from password", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    // base64 of "aes-256-gcm:pa\x00ss"
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://YWVzLTI1Ni1nY206cGEAc3M=@1.2.3.4:8443'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.password).toBe("pass");
  });

  it("parse_ss: missing port → null", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://aes-256-gcm:test-pw@s.example.com'; rm -f ${tmpUc}`,
    );
    expect(r.stdout.trim()).toBe("null");
  });

  it("parse_trojan: full URL with sni", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'trojan://trojan-pw@t.example.com:443?sni=t.example.com#myname'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.type).toBe("trojan");
    expect(obj.server).toBe("t.example.com");
    expect(obj.server_port).toBe(443);
    expect(obj.password).toBe("trojan-pw");
    const tls = obj.tls as Record<string, unknown>;
    expect(tls.server_name).toBe("t.example.com");
    expect(tls.enabled).toBe(true);
  });

  it("parse_trojan: no host:port → null", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'trojan://trojan-pw@'; rm -f ${tmpUc}`,
    );
    expect(r.stdout.trim()).toBe("null");
  });

  it("url_decode strips control chars from ss password", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    // password contains %00 (NUL), %0a (LF), %09 (TAB)
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'ss://aes-256-gcm:pa%00ss%0aword%09end@1.2.3.4:8443#san'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.password).toBe("passwordend");
  });

  it("parse_trojan: control chars in password are dropped", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'trojan://pw%0aevil@h.example.com:443#san'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.password).toBe("pwevil");
  });

  it("parse_hy2: port out of range → null", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r1 = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'hy2://pw@h.example.com:99999'`,
    );
    const r2 = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'hy2://pw@h.example.com:0'; rm -f ${tmpUc}`,
    );
    expect(r1.stdout.trim()).toBe("null");
    expect(r2.stdout.trim()).toBe("null");
  });

  it("parse_hy2: password control chars are dropped", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'hy2://pw%00boom@h.example.com:443'; rm -f ${tmpUc}`,
    );
    const obj = JSON.parse(r.stdout) as Record<string, unknown>;
    expect(obj.password).toBe("pwboom");
  });

  it("parse_vless: port out of range → null", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'vless://u@h.example.com:70000'; rm -f ${tmpUc}`,
    );
    expect(r.stdout.trim()).toBe("null");
  });

  it("safe_tag fallback is deterministic", async () => {
    const tmpUc = `/tmp/sb-parse-${Date.now()}.uc`;
    await putFile(
      `let outbound = require("outbound"); let parsed = outbound.parse_proxy_url(ARGV[0]); print(parsed == null ? "null" : sprintf("%J", parsed));`,
      tmpUc,
    );
    // VMESS_BAD_TAG is undefined in the shell test → empty string → "vmess://" is a bad URL
    const r1 = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'vmess://'`,
    );
    const r2 = await exec(
      `cd /tmp/work && ucode -L ${LIB} ${tmpUc} 'vmess://'; rm -f ${tmpUc}`,
    );
    expect(r1.stdout.trim()).toBe(r2.stdout.trim());
  });

  it("C2.1.10: PROXY_SCHEME_RE shared scheme constant present in subscription.uc", async () => {
    const content = readFileSync(`${HOST_SHARE}/subscription.uc`, "utf8");
    expect(content).toMatch(
      /PROXY_SCHEME_RE\s*=\s*\/\^\(vmess\|vless\|ss\|trojan\|hy2\|hysteria2\)/,
    );
    expect(content).toMatch(/match\(t, PROXY_SCHEME_RE\)/);
    expect(content).not.toMatch(/PROXY_SCHEME_RE.*http/);
  });

  it("C2.1.10: non-scheme b64 payload yields no output file", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // b64("visit https://example.com/path") = "dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo"
    await putFile("dmlzaXQgaHR0cHM6Ly9leGFtcGxlLmNvbS9wYXRo", `${dir}/body`);
    await putFile(
      uciSub("subC", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null || true`,
    );
    const check = await exec(
      `test -f ${dir}/runtime/sub_subC.txt && echo EXISTS || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("MISSING");
    await exec(`rm -rf ${dir}`);
  });

  it("C2.1.11: subscription URL match is case-insensitive (structural)", () => {
    const content = readFileSync(`${HOST_SHARE}/subscription.uc`, "utf8");
    expect(content).toMatch(/match\(lc\(t\)/);
  });

  it("C2.1.11: plaintext body with HTTPS:// is accepted", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("HTTPS://example.test/upstream\n", `${dir}/body`);
    await putFile(
      uciSub("subD", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null || true`,
    );
    const check = await exec(
      `test -s ${dir}/runtime/sub_subD.txt && echo ok || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("ok");
    const urlCheck = await exec(
      `grep -qi '^HTTPS://' ${dir}/runtime/sub_subD.txt && echo found || echo NOTFOUND`,
    );
    expect(urlCheck.stdout.trim()).toBe("found");
    await exec(`rm -rf ${dir}`);
  });

  it("C2.3.11: detect_rs_format strips URL query before suffix check", async () => {
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} -e '
let h = require("helpers");
printf("%s\\n", h.detect_rs_format("https://x/y.srs?ver=1", null));
printf("%s\\n", h.detect_rs_format("https://x/y.json?token=abc", null));
printf("%s\\n", h.detect_rs_format("https://x/y.srs#frag", null));
'`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("binary\nsource\nbinary");
  });

  it("C2.3.12: is_outbound_proxy_kind works for vless/interface", async () => {
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} -e '
let h = require("helpers");
printf("%s\\n", h.is_outbound_proxy_kind("vless"));
printf("%s\\n", h.is_outbound_proxy_kind("interface"));
'`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("true\nfalse");
  });

  it("C2.3.12: all active proxy kinds present in OUTBOUND_PROXY_KINDS", async () => {
    const r = await exec(
      `cd /tmp/work && ucode -L ${LIB} -e '
let h = require("helpers");
let want = ["vless","trojan","hysteria2","shadowsocks"];
let ok = true;
for (let t in want) if (!h.is_outbound_proxy_kind(t)) ok = false;
printf("%s\\n", ok ? "all-covered" : "missing");
'`,
    );
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("all-covered");
  });

  it("S3-1: fetch-subs writes output atomically, no tmp leftovers", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // b64("vless://uuid@host:443\n")
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    await putFile(
      uciSub("subA", { sub_url: "https://example.test/sub" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `test -s ${dir}/runtime/sub_subA.txt && echo ok || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("ok");
    // No .tmp.* leftovers
    const leftovers = await exec(
      `count=0; for f in ${dir}/runtime/sub_subA.txt.tmp.*; do [ -e "$f" ] && count=$((count+1)); done; echo $count`,
    );
    expect(leftovers.stdout.trim()).toBe("0");
    // Structural: fs.rename must appear in subscription.uc
    const content = readFileSync(`${HOST_SHARE}/subscription.uc`, "utf8");
    expect(content).toMatch(/fs\.rename\(/);
    await exec(`rm -rf ${dir}`);
  });

  it("S3-2: under-cap valid body is written", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("vless://uuid@host:443\n", `${dir}/body`);
    await putFile(
      uciSub("subBig", { sub_url: "https://example.test/big" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null`,
    );
    const check = await exec(
      `test -s ${dir}/runtime/sub_subBig.txt && echo ok || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("ok");
    const content = await exec(
      `grep '^vless://uuid@host:443' ${dir}/runtime/sub_subBig.txt || echo MISSING`,
    );
    expect(content.stdout).toContain("vless://uuid@host:443");
    await exec(`rm -rf ${dir}`);
  });

  it("S3-2: oversize valid body rejected by post-read size guard", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    // Create a body > 8 MiB: valid first line + 9 MB of padding
    await exec(
      `{ printf 'vless://uuid@host:443\\n'; head -c 9000000 /dev/zero | tr '\\0' 'a'; printf '\\n'; } >${dir}/body`,
    );
    await putFile(
      uciSub("subBig", { sub_url: "https://example.test/big" }),
      `${dir}/singbox-ui`,
    );
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>/dev/null || true`,
    );
    const check = await exec(
      `test -f ${dir}/runtime/sub_subBig.txt && echo EXISTS || echo MISSING`,
    );
    expect(check.stdout.trim()).toBe("MISSING");
    await exec(`rm -rf ${dir}`);
  });

  it("S3-4: NaN sub_interval clamps to default so refresh still runs", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile("dmxlc3M6Ly91dWlkQGhvc3Q6NDQzCg==", `${dir}/body`);
    await putFile(
      `config outbound 'subN'\n\toption type 'subscription'\n\toption sub_url 'https://example.test/sub'\n\toption sub_interval 'abc'\n`,
      `${dir}/singbox-ui`,
    );
    // seed stale cache file dated in 1970
    await putFile("vless://old@host:1\n", `${dir}/runtime/sub_subN.txt`);
    await exec(`touch -t 197001020000 ${dir}/runtime/sub_subN.txt`);
    await exec(`> ${dir}/curl.log`);
    await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime FAKE_BODY_FILE=${dir}/body FAKE_CURL_LOG=${dir}/curl.log SINGBOX_NO_RELOAD=1 CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} refresh 2>/dev/null`,
    );
    const log = await exec(`cat ${dir}/curl.log`);
    expect(log.stdout.trim().length).toBeGreaterThan(0);
    await exec(`rm -rf ${dir}`);
  });

  it("S3-8: log_err lines carry an 'error:' tag", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/bin ${dir}/runtime`);
    await putFile(CURL_STUB, `${dir}/bin/curl`);
    await exec(`chmod +x ${dir}/bin/curl`);
    await putFile(
      `config outbound 'notasub'\n\toption type 'interface'\n\toption interface 'wan'\n`,
      `${dir}/singbox-ui`,
    );
    const r = await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir} SINGBOX_TMPDIR=${dir}/runtime CURL=${dir}/bin/curl PATH=${dir}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin ucode -L ${LIB} ${SUB_UC} fetch-subs 2>&1 1>/dev/null || true`,
    );
    expect(r.stdout).toMatch(/error:.*no subscription outbounds/i);
    await exec(`rm -rf ${dir}`);
  });

  it("scoping: any_subs_stale honors per-section only arg", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/uci ${dir}/run`);
    await putFile(
      `config outbound 'one'\n\toption type 'subscription'\n\toption enabled '1'\n\toption sub_url 'https://e/one'\n\toption sub_interval '99999'\nconfig outbound 'two'\n\toption type 'subscription'\n\toption enabled '1'\n\toption sub_url 'https://e/two'\n\toption sub_interval '99999'\n`,
      `${dir}/uci/singbox-ui`,
    );
    // 'one' has a freshly-written body (not stale); 'two' has none (stale/missing)
    await putFile("vless://x\n", `${dir}/run/sub_one.txt`);

    const probeContent = `
let s=require("subscription");
let uci=require("uci"); let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
let only = getenv("SCOPE_ONLY") || null;
print(s._any_subs_stale_for_test(cur, false, only) ? "stale" : "fresh");
`;
    const tmpUc = `/tmp/sbscope-${Date.now()}.uc`;
    await putFile(probeContent, tmpUc);

    const scope = async (only: string) =>
      exec(
        `cd /tmp/work && env UCI_CONFIG_DIR=${dir}/uci SINGBOX_TMPDIR=${dir}/run SCOPE_ONLY=${only} ucode -L ${LIB} -L ${SHARE} ${tmpUc}`,
      );

    const r1 = await scope("one");
    expect(r1.stdout.trim()).toBe("fresh");
    const r2 = await scope("two");
    expect(r2.stdout.trim()).toBe("stale");
    const r3 = await scope("");
    expect(r3.stdout.trim()).toBe("stale");

    await exec(`rm -f ${tmpUc}; rm -rf ${dir}`);
  });

  it("auto_update gate: non-force skipped when flag=0, force bypasses", async () => {
    const dir = tmpDir();
    await exec(`mkdir -p ${dir}/uci`);
    await putFile(
      `config subscriptions 'subscriptions'\n\toption auto_update '0'\n`,
      `${dir}/uci/singbox-ui`,
    );

    const probeContent = `
let s=require("subscription"); let uci=require("uci");
let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
print(s._subs_refresh_allowed_for_test(cur, getenv("GATE_FORCE")==="1") ? "yes" : "no");
`;
    const tmpUc = `/tmp/sbgate-${Date.now()}.uc`;
    await putFile(probeContent, tmpUc);

    const gate = async (force: string) =>
      exec(
        `cd /tmp/work && env UCI_CONFIG_DIR=${dir}/uci GATE_FORCE=${force} ucode -L ${LIB} -L ${SHARE} ${tmpUc}`,
      );

    const r0 = await gate("0");
    expect(r0.stdout.trim()).toBe("no");
    const r1 = await gate("1");
    expect(r1.stdout.trim()).toBe("yes");

    // flag=1: non-force must be allowed
    const dir2 = tmpDir();
    await exec(`mkdir -p ${dir2}/uci`);
    await putFile(
      `config subscriptions 'subscriptions'\n\toption auto_update '1'\n`,
      `${dir2}/uci/singbox-ui`,
    );
    const probe2 = `
let s=require("subscription"); let uci=require("uci"); let cur=uci.cursor(getenv("UCI_CONFIG_DIR"));
print(s._subs_refresh_allowed_for_test(cur, false) ? "yes" : "no");
`;
    const tmpUc2 = `/tmp/sbgate2-${Date.now()}.uc`;
    await putFile(probe2, tmpUc2);
    const r2 = await exec(
      `cd /tmp/work && env UCI_CONFIG_DIR=${dir2}/uci ucode -L ${LIB} -L ${SHARE} ${tmpUc2}`,
    );
    expect(r2.stdout.trim()).toBe("yes");

    await exec(`rm -f ${tmpUc} ${tmpUc2}; rm -rf ${dir} ${dir2}`);
  });
});
