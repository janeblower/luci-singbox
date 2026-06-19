import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Port of tests/backend/test_audit_g3_clash.sh
// Regression for GROUP G3 Clash-API findings in the rpcd handler:
//   6.2 — bearer secret must NOT appear in curl argv; goes through 0600 tmpfile
//   6.3 — crafted listen/bad-port falls back to loopback defaults (SSRF guard)
//   6.4 — clash_mutate rejects a non-string body
//   RPC-2 — IPv6 loopback ::1 must be accepted and bracketed in URL

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? `${WORK}/singbox-ui/root/usr/share/singbox-ui/lib`;
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
const TMP = `/tmp/sb-g3-${process.pid}`;
const CURL_STUB = `${TMP}/curl`;
const CURL_LOG = `${TMP}/curl.log`;

// Fake curl: records argv, snapshots -H @<file> header file before it's
// deleted, echoes a tiny JSON body so clash_proxy emits ok.
const CURL_STUB_SCRIPT = `#!/bin/sh
echo "curl args: $*" >> ${CURL_LOG}
prev=""
for a in "$@"; do
  case "$prev" in
    -H)
      case "$a" in
        @*)
          f="\${a#@}"
          [ -f "$f" ] && {
            cat "$f" > ${TMP}/hdrfile.content
            { stat -c '%a' "$f" 2>/dev/null \\
              || stat -f '%Lp' "$f" 2>/dev/null \\
              || ls -l "$f" 2>/dev/null | awk 'NR==1{print $1}'; } \\
              > ${TMP}/hdrfile.mode 2>/dev/null || true
          }
          ;;
        *) echo "INLINE-HEADER:$a" >> ${CURL_LOG} ;;
      esac
      ;;
  esac
  prev="$a"
done
echo '{"ok":true}'
`;

async function setup(): Promise<void> {
  await exec(`mkdir -p ${TMP}`);
  await putFile(CURL_STUB_SCRIPT, CURL_STUB);
  await exec(`chmod +x ${CURL_STUB}`);
}

async function teardown(): Promise<void> {
  await exec(`rm -rf ${TMP}`);
}

// Run the rpcd handler method with the given stdin JSON and env vars.
async function runClash(
  method: string,
  stdinJson: string,
  extraEnv: string,
): Promise<{ stdout: string; exitCode: number }> {
  const r = await exec(
    `cd ${WORK} && echo ${JSON.stringify(stdinJson)} | ${extraEnv} ucode -L ${LIB} ${HANDLER} call ${method}`,
  );
  return { stdout: r.stdout.trim(), exitCode: r.exitCode };
}

async function clearLog(): Promise<void> {
  await exec(`> ${CURL_LOG}; rm -f ${TMP}/hdrfile.content ${TMP}/hdrfile.mode`);
}

async function readLog(): Promise<string> {
  const r = await exec(`cat ${CURL_LOG} 2>/dev/null || true`);
  return r.stdout;
}

async function readHdrContent(): Promise<string> {
  const r = await exec(`cat ${TMP}/hdrfile.content 2>/dev/null || true`);
  return r.stdout.trim();
}

async function readHdrMode(): Promise<string> {
  const r = await exec(`cat ${TMP}/hdrfile.mode 2>/dev/null || true`);
  return r.stdout.trim();
}

async function hdrFileExists(): Promise<boolean> {
  // The @<file> path should have been unlinked by clash_proxy after the call
  const r = await exec(
    `grep -o '@[^ ]*' ${CURL_LOG} 2>/dev/null | head -1 || true`,
  );
  const atFile = r.stdout.trim().replace(/^@/, "");
  if (!atFile) return false;
  const check = await exec(`[ -f ${atFile} ] && echo yes || echo no`);
  return check.stdout.trim() === "yes";
}

const BASE_ENV = `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=supersecrettoken`;

describe("audit_g3_clash (6.2 secret tmpfile / 6.3 SSRF guard / 6.4 body type / RPC-2 IPv6)", () => {
  useGuest();

  it("setup tmpdir and curl stub", async () => {
    await setup();
    // Verify the stub was installed
    const r = await exec(`[ -x ${CURL_STUB} ] && echo ok || echo fail`);
    expect(r.stdout.trim()).toBe("ok");
  });

  // ---- 6.2: secret never in argv; lands in a 0600 tmpfile via -H @file ----

  it("6.2: clash_get status==ok", async () => {
    await clearLog();
    const r = await runClash("clash_get", '{"path":"/connections"}', BASE_ENV);
    let out: Record<string, unknown> = {};
    try {
      out = JSON.parse(r.stdout);
    } catch (_e) {
      // ok
    }
    expect(out.status).toBe("ok");
  });

  it("6.2: secret NOT in recorded curl argv", async () => {
    const log = await readLog();
    expect(log).not.toContain("supersecrettoken");
  });

  it("6.2: curl argv references header by @file (not inline)", async () => {
    const log = await readLog();
    expect(log).toMatch(/@\//);
  });

  it("6.2: header file content contains the bearer secret", async () => {
    const hdr = await readHdrContent();
    expect(hdr).toContain("supersecrettoken");
  });

  it("6.2: header file was mode 0600 (octal or ls perm string)", async () => {
    const mode = await readHdrMode();
    // Accept numeric '600' or ls perm '-rw-------'
    expect(mode).toMatch(/600|-rw-------/);
  });

  it("6.2: header file unlinked after call (not accessible at @<path>)", async () => {
    const exists = await hdrFileExists();
    expect(exists).toBe(false);
  });

  // ---- 6.3: crafted listen / bad port fall back to loopback defaults ----

  it("6.3: crafted listen does not survive into the curl URL", async () => {
    await clearLog();
    await runClash(
      "clash_get",
      '{"path":"/connections"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN='evil.com/x?' CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    const log = await readLog();
    expect(log).not.toContain("evil.com");
  });

  it("6.3: out-of-range port does not survive; loopback default URL used", async () => {
    await clearLog();
    await runClash(
      "clash_get",
      '{"path":"/connections"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=99999 CLASH_SECRET=tok`,
    );
    const log = await readLog();
    expect(log).not.toContain("99999");
    // Should fall back to default port 9090
    expect(log).toContain("9090");
  });

  it("6.3: valid non-loopback listen + in-range port is honoured", async () => {
    await clearLog();
    await runClash(
      "clash_get",
      '{"path":"/connections"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=192.168.1.1 CLASH_PORT=7890 CLASH_SECRET=tok`,
    );
    const log = await readLog();
    expect(log).toContain("192.168.1.1");
    expect(log).toContain("7890");
  });

  // ---- RPC-2: IPv6 loopback ::1 accepted and bracketed ----

  it("RPC-2: ::1 listen NOT fallen back to 127.0.0.1", async () => {
    await clearLog();
    await runClash(
      "clash_get",
      '{"path":"/connections"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN='::1' CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    const log = await readLog();
    expect(log).not.toContain("127.0.0.1");
  });

  it("RPC-2: ::1 bracketed in URL as http://[::1]:9090/...", async () => {
    const log = await readLog();
    expect(log).toContain("[::1]");
  });

  // ---- 6.4: clash_mutate rejects a non-string body ----

  it("6.4: object body rejected with error", async () => {
    const r = await runClash(
      "clash_mutate",
      '{"method":"POST","path":"/configs","body":{"mode":"global"}}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    let out: Record<string, unknown> = {};
    try {
      out = JSON.parse(r.stdout);
    } catch (_e) {
      // ok
    }
    expect(out.status).toBe("error");
    expect(String(out.message ?? "")).toContain("body must be a string");
  });

  it("6.4: numeric body rejected with error", async () => {
    const r = await runClash(
      "clash_mutate",
      '{"method":"POST","path":"/configs","body":42}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    let out: Record<string, unknown> = {};
    try {
      out = JSON.parse(r.stdout);
    } catch (_e) {
      // ok
    }
    expect(out.status).toBe("error");
    expect(String(out.message ?? "")).toContain("body must be a string");
  });

  it("6.4: real string body still works (no regression)", async () => {
    await clearLog();
    const r = await runClash(
      "clash_mutate",
      '{"method":"PATCH","path":"/configs","body":"{\\"mode\\":\\"global\\"}"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    let out: Record<string, unknown> = {};
    try {
      out = JSON.parse(r.stdout);
    } catch (_e) {
      // ok
    }
    expect(out.status).toBe("ok");
    const log = await readLog();
    expect(log).toContain("--data");
  });

  it("6.4: null/absent body still works (DELETE no body)", async () => {
    await clearLog();
    const r = await runClash(
      "clash_mutate",
      '{"method":"DELETE","path":"/connections"}',
      `CLASH_CURL=${CURL_STUB} CLASH_LISTEN=127.0.0.1 CLASH_PORT=9090 CLASH_SECRET=tok`,
    );
    let out: Record<string, unknown> = {};
    try {
      out = JSON.parse(r.stdout);
    } catch (_e) {
      // ok
    }
    expect(out.status).toBe("ok");
  });

  it("teardown tmpdir", async () => {
    await teardown();
  });
});
