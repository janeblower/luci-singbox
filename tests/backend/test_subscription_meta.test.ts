import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SHARE = "/tmp/work/singbox-ui/root/usr/share/singbox-ui";

async function runProbe(
  probePath: string,
  env: Record<string, string> = {},
): Promise<{ stdout: string; stderr: string; exitCode: number }> {
  const envStr = Object.entries(env)
    .map(([k, v]) => `${k}=${v}`)
    .join(" ");
  const prefix = envStr ? `env ${envStr} ` : "";
  return exec(
    `cd /tmp/work && ${prefix}ucode -L ${LIB} -L ${SHARE} ${probePath}`,
  );
}

describe("test_subscription_meta", () => {
  useGuest();

  it("parses subscription-userinfo and content-disposition title", async () => {
    const probe = `
let sub = require("subscription");
let hdr = "HTTP/2 200\\r\\n" +
  "content-type: text/plain\\r\\n" +
  "subscription-userinfo: upload=455; download=2576; total=107374182400; expire=1672502400\\r\\n" +
  "content-disposition: attachment; filename=\\"My Sub\\"\\r\\n\\r\\n";
print(sprintf("%J", sub._parse_headers_for_test(hdr)));
`;
    const dir = `/tmp/sbmeta-1-${Date.now()}`;
    await exec(`mkdir -p ${dir}`);
    const probePath = `${dir}/probe.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath);
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    const obj = JSON.parse(r.stdout);
    expect(obj.userinfo?.total).toBe(107374182400);
    expect(obj.userinfo?.expire).toBe(1672502400);
    expect(obj.userinfo?.upload).toBe(455);
    expect(obj.title).toBe("My Sub");
  });

  it("returns empty object (no userinfo key) when headers are missing", async () => {
    const probe = `
let sub = require("subscription");
let r = sub._parse_headers_for_test("HTTP/1.1 200 OK\\r\\nserver: x\\r\\n\\r\\n");
print(sprintf("%J", r));
`;
    const dir = `/tmp/sbmeta-2-${Date.now()}`;
    await exec(`mkdir -p ${dir}`);
    const probePath = `${dir}/probe.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath);
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    const obj = JSON.parse(r.stdout);
    expect("userinfo" in obj).toBe(false);
  });

  it("SEC-5: profile-title base64 decode, malformed fallback, empty-base64 omit", async () => {
    const probe = `
let sub = require("subscription");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:SGVsbG8=\\r\\n")));
print("\\n");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:@@@notb64@@@\\r\\n")));
print("\\n");
print(sprintf("%J", sub._parse_headers_for_test("profile-title: base64:\\r\\n")));
print("\\n");
`;
    const dir = `/tmp/sbmeta-pt-${Date.now()}`;
    await exec(`mkdir -p ${dir}`);
    const probePath = `${dir}/probe_pt.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath);
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    // Split on blank lines between JSON objects
    const parts = r.stdout
      .trim()
      .split("\n")
      .filter((l) => l.trim() !== "");
    const [r1, r2, r3] = parts.map((p) => JSON.parse(p));

    // Valid base64 "SGVsbG8=" → "Hello"
    expect(r1.title).toBe("Hello");

    // Malformed base64: fall back to raw value WITHOUT the "base64:" prefix
    expect(r2.title).toBe("@@@notb64@@@");
    expect(r2.title).not.toContain("base64:");

    // Empty base64 payload: title should not be emitted at all
    expect("title" in r3).toBe(false);
  });

  it("cmd_sub_status picks up an existing .meta sidecar", async () => {
    const dir = `/tmp/sbmeta-3-${Date.now()}`;
    await exec(`mkdir -p ${dir}/cfg ${dir}/run`);

    const uciCfg =
      `config outbound 'subM'\n` +
      `\toption type 'subscription'\n` +
      `\toption sub_url 'https://e/m'\n`;
    await putFile(uciCfg, `${dir}/cfg/singbox-ui`);

    // Pre-write the sidecar
    await putFile(
      `{"title":"Hello","userinfo":{"total":100,"download":10}}`,
      `${dir}/run/sub_subM.meta`,
    );
    // Pre-write the body
    await putFile(`vless://x@h:1\n`, `${dir}/run/sub_subM.txt`);

    const probe = `
let sub = require("subscription");
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
print(sprintf("%J", sub._cmd_sub_status_for_test(uci)));
`;
    const probePath = `${dir}/probe3.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath, {
      UCI_CONFIG_DIR: `${dir}/cfg`,
      SINGBOX_TMPDIR: `${dir}/run`,
    });
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    const status = JSON.parse(r.stdout);
    // status is an array of per-sub objects; find our sub
    const entry = Array.isArray(status)
      ? status.find((e: { name?: string }) => e.name === "subM")
      : status;
    expect(entry?.title ?? status?.title).toBe("Hello");
    const userinfo = entry?.userinfo ?? status?.userinfo;
    expect(userinfo?.total).toBe(100);
  });

  it("SEC-7: stale .meta sidecar is removed when refetch yields no userinfo/title", async () => {
    const dir = `/tmp/sbmeta-sec7-${Date.now()}`;
    await exec(`mkdir -p ${dir}/cfg ${dir}/run`);

    const uciCfg =
      `config outbound 'subS'\n` +
      `\toption type 'subscription'\n` +
      `\toption sub_url 'https://e/s'\n`;
    await putFile(uciCfg, `${dir}/cfg/singbox-ui`);

    const metaPath = `${dir}/run/sub_subS.meta`;

    const probe = `
let fs = require("fs");
let sub = require("subscription");
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
// Pass 1: body + profile-title header → meta sidecar should be written.
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs) {
    let b = fs.open(j.body_path, "w"); b.write("vless://x@h:1#n\\n"); b.close();
    let h = fs.open(j.hdr_path, "w");
    h.write("HTTP/2 200\\r\\nprofile-title: First Title\\r\\nsubscription-userinfo: upload=1; download=2; total=3; expire=4\\r\\n\\r\\n");
    h.close();
  }
});
sub._cmd_fetch_subs_for_test(uci);
let m1 = fs.stat("${metaPath}");
print("after_pass1_meta_exists=", (m1 != null) ? "yes" : "no"); print("\\n");
// Pass 2: body but a header dump with NO userinfo/title → stale meta must go.
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs) {
    let b = fs.open(j.body_path, "w"); b.write("vless://x@h:1#n\\n"); b.close();
    let h = fs.open(j.hdr_path, "w");
    h.write("HTTP/2 200\\r\\nserver: nginx\\r\\n\\r\\n");
    h.close();
  }
});
sub._cmd_fetch_subs_for_test(uci);
let m2 = fs.stat("${metaPath}");
print("after_pass2_meta_exists=", (m2 != null) ? "yes" : "no"); print("\\n");
`;
    const probePath = `${dir}/probe_sec7.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath, {
      UCI_CONFIG_DIR: `${dir}/cfg`,
      SINGBOX_TMPDIR: `${dir}/run`,
    });
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("after_pass1_meta_exists=yes");
    expect(r.stdout).toContain("after_pass2_meta_exists=no");
  });

  it("FET-2: a hard fetch failure (no valid URLs) unlinks the stale .meta sidecar", async () => {
    const dir = `/tmp/sbmeta-fet2-${Date.now()}`;
    await exec(`mkdir -p ${dir}/cfg ${dir}/run`);

    const uciCfg =
      `config outbound 'subF'\n` +
      `\toption type 'subscription'\n` +
      `\toption sub_url 'https://e/f'\n`;
    await putFile(uciCfg, `${dir}/cfg/singbox-ui`);

    const metaPath = `${dir}/run/sub_subF.meta`;

    const probe = `
let fs = require("fs");
let sub = require("subscription");
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
// Pass 1: a good body + title header writes the meta sidecar.
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs) {
    let b = fs.open(j.body_path, "w"); b.write("vless://x@h:1#n\\n"); b.close();
    let h = fs.open(j.hdr_path, "w");
    h.write("HTTP/2 200\\r\\nprofile-title: Plan A\\r\\n\\r\\n");
    h.close();
  }
});
sub._cmd_fetch_subs_for_test(uci);
let m1 = fs.stat("${metaPath}");
print("after_pass1_meta_exists=", (m1 != null) ? "yes" : "no"); print("\\n");
// Pass 2: a garbage body (no valid proxy URL) is a hard failure; the now-stale
// meta sidecar from pass 1 must be removed, not left to mislead the dashboard.
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs) {
    let b = fs.open(j.body_path, "w"); b.write("upstream error page\\n"); b.close();
    let h = fs.open(j.hdr_path, "w"); h.write("HTTP/2 200\\r\\n\\r\\n"); h.close();
  }
});
sub._cmd_fetch_subs_for_test(uci);
let m2 = fs.stat("${metaPath}");
print("after_pass2_meta_exists=", (m2 != null) ? "yes" : "no"); print("\\n");
`;
    const probePath = `${dir}/probe_fet2.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath, {
      UCI_CONFIG_DIR: `${dir}/cfg`,
      SINGBOX_TMPDIR: `${dir}/run`,
    });
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    expect(r.stdout).toContain("after_pass1_meta_exists=yes");
    expect(r.stdout).toContain("after_pass2_meta_exists=no");
  });
});
