import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

// Phase 4 (U1-U3, D1-D2) + Phase 5 (C1-C4, metadata). Everything runs through
// the production CLI (`subscription.uc fetch-subs` / `refresh`) with the curl,
// init.d, tmpfs and persistent-cache seams pointed at a scratch dir.

const LIB = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SUB_UC = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/subscription.uc";

let counter = 0;
function tmpDir(): string {
  return `/tmp/sbcache-${Date.now()}-${counter++}`;
}

const URI_BODY = "trojan://pw@t.example.com:443#T\n";

// A curl stub that records its argv and serves FAKE_BODY_FILE. UA_BODY_DIR, if
// set, lets a test serve a DIFFERENT body per User-Agent: $UA_BODY_DIR/<ua>.
const CURL_STUB = `#!/bin/sh
out=""; hdr=""; ua=""; prev=""
for a in "$@"; do
  case "$prev" in -o) out="$a" ;; -D) hdr="$a" ;; -A) ua="$a" ;; esac
  prev="$a"
done
echo "$@" >>"\${FAKE_CURL_LOG:-/dev/null}"
rc="\${FAKE_CURL_RC:-0}"
if [ -n "$hdr" ]; then
  printf 'HTTP/1.1 200 OK\\r\\n' >"$hdr"
  printf '%b\\r\\n\\r\\n' "\${FAKE_HEADERS:-server: stub}" >>"$hdr"
fi
if [ "$rc" != "0" ]; then exit "$rc"; fi
src="\${FAKE_BODY_FILE:-/dev/null}"
if [ -n "\${UA_BODY_DIR:-}" ]; then
  key=$(printf '%s' "$ua" | tr -c 'A-Za-z0-9' '_')
  if [ -f "\${UA_BODY_DIR}/\${key}" ]; then src="\${UA_BODY_DIR}/\${key}"; else src="\${UA_BODY_DIR}/default"; fi
fi
[ -n "$out" ] && cat "$src" >"$out"
exit 0
`;

// init.d stub: appends a line per reload so a test can count them.
const INITD_STUB = `#!/bin/sh
echo "$1" >>"\${RELOAD_LOG:-/dev/null}"
exit 0
`;

interface Env {
  [k: string]: string;
}

async function setup(uciOpts: Record<string, string> = {}): Promise<{
  dir: string;
  env: (extra?: Env) => string;
  run: (
    args: string,
    extra?: Env,
  ) => Promise<{ stdout: string; stderr: string }>;
}> {
  const dir = tmpDir();
  await exec(`mkdir -p ${dir}/bin ${dir}/rt ${dir}/cache ${dir}/uci ${dir}/ua`);
  await putFile(CURL_STUB, `${dir}/bin/curl`);
  await putFile(INITD_STUB, `${dir}/bin/initd`);
  await exec(`chmod +x ${dir}/bin/curl ${dir}/bin/initd`);
  await putFile(URI_BODY, `${dir}/body`);
  const extra = Object.entries({
    sub_url: "https://example.test/sub",
    ...uciOpts,
  })
    .map(([k, v]) => `\toption ${k} '${v}'`)
    .join("\n");
  await putFile(
    `config outbound 'sub1'\n\toption type 'subscription'\n${extra}\n`,
    `${dir}/uci/singbox-ui`,
  );
  const env = (e: Env = {}): string =>
    Object.entries({
      UCI_CONFIG_DIR: `${dir}/uci`,
      SINGBOX_TMPDIR: `${dir}/rt`,
      SINGBOX_SUB_CACHE: `${dir}/cache`,
      CURL: `${dir}/bin/curl`,
      SINGBOX_INITD: `${dir}/bin/initd`,
      RELOAD_LOG: `${dir}/reload.log`,
      FAKE_BODY_FILE: `${dir}/body`,
      FAKE_CURL_LOG: `${dir}/curl.log`,
      SINGBOX_RETRY_SLEEP: "0",
      SINGBOX_SB_VERSION: "1.11.0",
      ...e,
    })
      .map(([k, v]) => `${k}='${v}'`)
      .join(" ");
  const run = (args: string, e: Env = {}) =>
    exec(
      `cd /tmp/work && env ${env(e)} ucode -L ${LIB} ${SUB_UC} ${args} 2>&1`,
    );
  return { dir, env, run };
}

async function reloads(dir: string): Promise<number> {
  const r = await exec(`wc -l <${dir}/reload.log 2>/dev/null || echo 0`);
  return Number.parseInt(r.stdout.trim(), 10) || 0;
}

describe("test_subscription_cache", () => {
  useGuest();

  it("U2: the default User-Agent is sing-box/<version>, not a browser UA", async () => {
    const { dir, run } = await setup();
    await run("fetch-subs");
    const log = await exec(`cat ${dir}/curl.log`);
    expect(log.stdout).toContain("-A sing-box/1.11.0");
    expect(log.stdout).not.toContain("Chrome/");
    await exec(`rm -rf ${dir}`);
  });

  it("U1: a HTML stub on the first UA rotates to the next profile until the body PARSES", async () => {
    const { dir, run } = await setup();
    // sing-box UA -> HTML "open in the app" page (HTTP 200!); Happ -> real body
    await putFile("<html>open in the app</html>", `${dir}/ua/default`);
    await putFile(URI_BODY, `${dir}/ua/Happ_1_0`);
    await run("fetch-subs", { UA_BODY_DIR: `${dir}/ua` });
    const txt = await exec(
      `cat ${dir}/rt/sub_sub1.txt 2>/dev/null || echo MISSING`,
    );
    expect(txt.stdout).toContain("trojan://");
    // U1: the winning UA is cached on flash…
    const ua = await exec(`cat ${dir}/cache/sub_sub1.ua`);
    expect(ua.stdout.trim()).toBe("happ");
    // …and tried first on the next run (one curl call, not three)
    await exec(`: >${dir}/curl.log`);
    await run("fetch-subs", { UA_BODY_DIR: `${dir}/ua` });
    const n = await exec(`grep -c 'Happ/1.0' ${dir}/curl.log`);
    expect(Number.parseInt(n.stdout.trim(), 10)).toBe(1);
    const first = await exec(`head -1 ${dir}/curl.log`);
    expect(first.stdout).toContain("Happ/1.0");
    await exec(`rm -rf ${dir}`);
  });

  it("U3: a chosen profile id resolves to that client's UA; an unknown value is used verbatim", async () => {
    const { dir, run } = await setup({ sub_user_agent: "v2rayng" });
    await run("fetch-subs");
    const log = await exec(`head -1 ${dir}/curl.log`);
    expect(log.stdout).toContain("-A v2rayNG/1.8.5");
    await exec(`rm -rf ${dir}`);

    const legacy = await setup({ sub_user_agent: "curl/8.7.1" });
    await legacy.run("fetch-subs");
    const l2 = await exec(`head -1 ${legacy.dir}/curl.log`);
    expect(l2.stdout).toContain("-A curl/8.7.1");
    await exec(`rm -rf ${legacy.dir}`);
  });

  it("§2.3: provider headers (X-HWID / X-Device-OS / locale) are sent; sub_auto_hwid=0 drops the HWID", async () => {
    const { dir, run } = await setup({ sub_hwid: "aaaa-bbbb-cccc-dddd" });
    await run("fetch-subs");
    const log = await exec(`cat ${dir}/curl.log`);
    expect(log.stdout).toContain("X-HWID: aaaa-bbbb-cccc-dddd");
    expect(log.stdout).toContain("X-Device-OS: OpenWrt Linux");
    expect(log.stdout).toContain("X-Device-Locale: EN");
    expect(log.stdout).toContain("Accept-Language: ru-RU,en,*");
    await exec(`rm -rf ${dir}`);

    const off = await setup({ sub_auto_hwid: "0" });
    await off.run("fetch-subs");
    const l2 = await exec(`cat ${off.dir}/curl.log`);
    expect(l2.stdout).not.toContain("X-HWID:");
    await exec(`rm -rf ${off.dir}`);
  });

  it("D1: a transport failure is retried 3x, a DNS failure (curl 6) is not retried at all", async () => {
    const fail = await setup();
    await fail.run("fetch-subs", { FAKE_CURL_RC: "7" }); // connection refused
    const tries = await exec(`wc -l <${fail.dir}/curl.log`);
    // 3 attempts, and NO UA rotation: a host that does not answer does not answer
    // differently to another User-Agent, and the boot fetch is on a time budget.
    expect(Number.parseInt(tries.stdout.trim(), 10)).toBe(3);
    await exec(`rm -rf ${fail.dir}`);

    const dns = await setup();
    await dns.run("fetch-subs", { FAKE_CURL_RC: "6" }); // could not resolve host
    const t2 = await exec(`wc -l <${dns.dir}/curl.log`);
    expect(Number.parseInt(t2.stdout.trim(), 10)).toBe(1);
    await exec(`rm -rf ${dns.dir}`);
  });

  it("D2: curl is given --connect-timeout/--speed-time/--speed-limit and keeps --max-filesize", async () => {
    const { dir, run } = await setup();
    await run("fetch-subs");
    const log = await exec(`cat ${dir}/curl.log`);
    expect(log.stdout).toContain("--connect-timeout 15");
    expect(log.stdout).toContain("--speed-time 15");
    expect(log.stdout).toContain("--speed-limit 1");
    expect(log.stdout).toContain("--max-filesize 8388608");
    await exec(`rm -rf ${dir}`);
  });

  it("C1: the persistent cache survives a reboot (tmpfs wiped, network down)", async () => {
    const { dir, run } = await setup();
    await run("fetch-subs");
    // busybox has no `stat -c`; ls -ld is the portable read. Node lines carry
    // passwords — nothing here may be group- or world-readable.
    const perms = await exec(
      `ls -ld ${dir}/cache ${dir}/cache/sub_sub1.txt | cut -c1-10`,
    );
    expect(perms.stdout.trim().split("\n")).toEqual([
      "drwx------",
      "-rw-------",
    ]);

    // reboot: /tmp is a tmpfs, and the boot fetch fails (no WAN yet)
    await exec(`rm -rf ${dir}/rt && mkdir -p ${dir}/rt`);
    await run("fetch-subs", { FAKE_CURL_RC: "6" });
    const txt = await exec(
      `cat ${dir}/rt/sub_sub1.txt 2>/dev/null || echo MISSING`,
    );
    expect(txt.stdout).toContain("trojan://");
    await exec(`rm -rf ${dir}`);
  });

  it("C2: changing sub_url invalidates the cache instead of serving the old provider's nodes", async () => {
    const { dir, run } = await setup({ sub_interval: "86400" });
    await run("fetch-subs");
    expect((await exec(`cat ${dir}/rt/sub_sub1.txt`)).stdout).toContain(
      "t.example.com",
    );

    // fresh within sub_interval: a cron refresh must not even fetch
    await exec(`: >${dir}/curl.log`);
    await run("refresh");
    expect((await exec(`wc -l <${dir}/curl.log`)).stdout.trim()).toBe("0");

    // user points the section at a different provider: the profile no longer
    // matches, so the subscription is stale REGARDLESS of mtime…
    const newUci =
      `config outbound 'sub1'\n\toption type 'subscription'\n` +
      `\toption sub_url 'https://other.test/sub'\n\toption sub_interval '86400'\n`;
    await putFile(newUci, `${dir}/uci/singbox-ui`);
    await run("refresh", { FAKE_CURL_RC: "7" });
    expect((await exec(`wc -l <${dir}/curl.log`)).stdout.trim()).not.toBe("0");

    // …and the OLD provider's nodes are gone rather than routing traffic.
    const txt = await exec(
      `cat ${dir}/rt/sub_sub1.txt 2>/dev/null || echo GONE`,
    );
    expect(txt.stdout.trim()).toBe("GONE");
    await exec(`rm -rf ${dir}`);
  });

  it("C3: an unchanged node set does NOT reload sing-box (key order is not a change)", async () => {
    const { dir, run } = await setup();
    await run("refresh force");
    expect(await reloads(dir)).toBe(1);

    // same nodes, re-serialised with the lines in another order
    await putFile(
      "trojan://pw@t.example.com:443#T\nvless://uuid@v.example.com:443?security=tls#V\n",
      `${dir}/body`,
    );
    await run("refresh force");
    expect(await reloads(dir)).toBe(2);

    await putFile(
      "vless://uuid@v.example.com:443?security=tls#V\ntrojan://pw@t.example.com:443#T\n",
      `${dir}/body`,
    );
    await run("refresh force");
    expect(await reloads(dir)).toBe(2); // reordered, not changed -> no reload

    await putFile("trojan://pw@t.example.com:443#T\n", `${dir}/body`);
    await run("refresh force");
    expect(await reloads(dir)).toBe(3); // a node disappeared -> reload
    await exec(`rm -rf ${dir}`);
  });

  it("C4: a held lock makes a concurrent refresh skip (no second fetch, no second reload)", async () => {
    const { dir, run } = await setup();
    await run("refresh force");
    expect(await reloads(dir)).toBe(1);

    await exec(`mkdir ${dir}/rt/.sub.lock`);
    await exec(`: >${dir}/curl.log`);
    const r = await run("refresh force");
    expect(r.stdout).toContain("another refresh is running");
    expect((await exec(`wc -l <${dir}/curl.log`)).stdout.trim()).toBe("0");
    expect(await reloads(dir)).toBe(1);

    // a stale lock (older than 10 min) is broken, not honoured forever
    await exec(`touch -t 202001010000 ${dir}/rt/.sub.lock`);
    await run("refresh force");
    expect((await exec(`wc -l <${dir}/curl.log`)).stdout.trim()).not.toBe("0");
    await exec(`rm -rf ${dir}`);
  });

  it("F1: sub_cache_persist=0 keeps the cache out of flash; default persists it", async () => {
    const off = await setup({ sub_cache_persist: "0" });
    await off.run("fetch-subs");
    const offLs = await exec(
      `ls ${off.dir}/cache/sub_sub1.txt 2>/dev/null || echo MISSING`,
    );
    expect(offLs.stdout.trim()).toBe("MISSING");
    await exec(`rm -rf ${off.dir}`);

    const { dir, run } = await setup();
    await run("fetch-subs");
    const onLs = await exec(`ls ${dir}/cache/sub_sub1.txt`);
    expect(onLs.stdout.trim()).toBe(`${dir}/cache/sub_sub1.txt`);
    await exec(`rm -rf ${dir}`);
  });

  it("F1: sub_cache_persist=0 also skips the RESTORE side (flash -> tmpfs on boot), not just persist", async () => {
    // same shape as C1 (tmpfs wiped, network down forces the restore-from-flash
    // path), but toggling sub_cache_persist to prove the restore() gate itself
    // — C1 alone never flips the flag, so a broken gate there ships silently.
    const { dir, run } = await setup();
    await run("fetch-subs"); // persist ON (default): flash cache gets populated
    expect((await exec(`ls ${dir}/cache/sub_sub1.txt`)).stdout.trim()).toBe(
      `${dir}/cache/sub_sub1.txt`,
    );

    // flip to OFF, wipe tmpfs, fetch with the network down: restore must NOT
    // repopulate tmpfs from the (still-populated) flash cache.
    await putFile(
      `config outbound 'sub1'\n\toption type 'subscription'\n` +
        `\toption sub_url 'https://example.test/sub'\n\toption sub_cache_persist '0'\n`,
      `${dir}/uci/singbox-ui`,
    );
    await exec(`rm -rf ${dir}/rt && mkdir -p ${dir}/rt`);
    await run("fetch-subs", { FAKE_CURL_RC: "6" });
    expect(
      (
        await exec(`cat ${dir}/rt/sub_sub1.txt 2>/dev/null || echo MISSING`)
      ).stdout.trim(),
    ).toBe("MISSING");

    // flip back to the default (persist on): the identical wipe-then-fetch
    // DOES restore, proving the other direction of the same gate.
    await putFile(
      `config outbound 'sub1'\n\toption type 'subscription'\n` +
        `\toption sub_url 'https://example.test/sub'\n`,
      `${dir}/uci/singbox-ui`,
    );
    await exec(`rm -rf ${dir}/rt && mkdir -p ${dir}/rt`);
    await run("fetch-subs", { FAKE_CURL_RC: "6" });
    expect(
      (await exec(`cat ${dir}/rt/sub_sub1.txt 2>/dev/null || echo MISSING`))
        .stdout,
    ).toContain("trojan://");
    await exec(`rm -rf ${dir}`);
  });

  it("F1: flipping sub_cache_persist OFF removes a flash copy a prior persist-on fetch wrote", async () => {
    // The flag's stated purpose (UI + uci-schema.md) is keeping node passwords
    // off flash. A user who ran on the default (on), then flips it off for
    // exactly that reason, must not be left with the old credential-bearing copy
    // still sitting on flash — skipping persist() is not enough, the old file
    // has to be deleted.
    const { dir, run } = await setup();
    await run("fetch-subs"); // persist ON (default): flash copy written
    expect((await exec(`ls ${dir}/cache/sub_sub1.txt`)).stdout.trim()).toBe(
      `${dir}/cache/sub_sub1.txt`,
    );

    // flip the SAME section to persist OFF and refetch: the stale flash copy
    // must be gone, not merely left untouched.
    await putFile(
      `config outbound 'sub1'\n\toption type 'subscription'\n` +
        `\toption sub_url 'https://example.test/sub'\n\toption sub_cache_persist '0'\n`,
      `${dir}/uci/singbox-ui`,
    );
    await run("fetch-subs");
    expect(
      (
        await exec(`ls ${dir}/cache/sub_sub1.txt 2>/dev/null || echo GONE`)
      ).stdout.trim(),
    ).toBe("GONE");
    await exec(`rm -rf ${dir}`);
  });

  it("metadata: headers override the body preamble and reach sub_status normalized", async () => {
    const { dir, run } = await setup();
    // preamble in the body carries a title + support url; the header re-states
    // the title (and wins) and adds traffic/expiry/announce/refill
    await putFile(
      [
        "# profile-title: Body Title",
        "# support-url: https://support.example.com",
        "# announce: base64:SGVsbG8gd29ybGQ=",
        "trojan://pw@t.example.com:443#T",
        "",
      ].join("\n"),
      `${dir}/body`,
    );
    const headers = [
      "subscription-userinfo: upload=100; download=200; total=1000; expire=1900000000",
      "profile-title: base64:SGVhZGVyIFRpdGxl",
      "profile-web-page-url: https://panel.example.com",
      "announce-url: https://news.example.com",
      "subscription-refill-date: 2026-08-01",
      'content-disposition: attachment; filename="sub.txt"',
    ].join("\\r\\n");
    await run("fetch-subs", { FAKE_HEADERS: headers });

    const st = await run("sub-status");
    const arr = JSON.parse(st.stdout.trim().split("\n").pop() as string);
    const m = arr[0].metadata;
    expect(m.title).toBe("Header Title"); // header beats preamble
    expect(m.supportUrl).toBe("https://support.example.com"); // preamble-only key survives
    expect(m.announce).toBe("Hello world");
    expect(m.webPageUrl).toBe("https://panel.example.com");
    expect(m.announceUrl).toBe("https://news.example.com");
    expect(m.refillDate).toBe(1785542400); // 2026-08-01T00:00:00Z
    expect(m.expire).toBe(1900000000);
    expect(m.fileName).toBe("sub.txt");
    expect(m.traffic).toEqual({
      used: 300,
      upload: 100,
      download: 200,
      total: 1000,
      remaining: 700,
      isUnlimited: false,
    });
    expect(arr[0].skipped).toBe(0);
    expect(arr[0].format).toBe("uri");
    await exec(`rm -rf ${dir}`);
  });

  it("metadata: hostile values are clamped (>1e13 userinfo, javascript: url, over-long title)", async () => {
    const { dir, run } = await setup();
    const long = "x".repeat(200);
    const headers = [
      "subscription-userinfo: total=99999999999999999; expire=99999999999999999; upload=5",
      `profile-title: ${long}`,
      "profile-web-page-url: javascript:alert(1)",
      "support-url: data:text/html,x",
    ].join("\\r\\n");
    await run("fetch-subs", { FAKE_HEADERS: headers });
    const st = await run("sub-status");
    const arr = JSON.parse(st.stdout.trim().split("\n").pop() as string);
    const m = arr[0].metadata;
    expect(m.title.length).toBe(120);
    expect(m.webPageUrl).toBeUndefined();
    expect(m.supportUrl).toBeUndefined();
    expect(m.expire).toBeUndefined(); // clamped away, not rendered
    expect(m.traffic.total).toBe(0);
    expect(m.traffic.isUnlimited).toBe(true);
    await exec(`rm -rf ${dir}`);
  });
});
