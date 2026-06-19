import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec, putFile } from "../helpers/ssh.ts";

const LIB = "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const SHARE = "/tmp/work/singbox-ui/root/usr/share/singbox-ui";

// Run a probe .uc file with both -L dirs and the given env vars.
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

describe("test_subscription_fetch", () => {
  useGuest();

  it("Test A: cmd_fetch_subs builds one job per enabled subscription with url/ua, no cfg_json", async () => {
    const dir = `/tmp/sbfetch-a-${Date.now()}`;
    await exec(`mkdir -p ${dir}/config ${dir}/tmp`);

    const uciCfg =
      `config outbound 'mysub'\n` +
      `\toption type 'subscription'\n` +
      `\toption sub_url 'https://sub.example.com/x'\n` +
      `\toption sub_user_agent 'v2rayNG/1.8.5'\n` +
      `\toption sub_interval '3600'\n\n` +
      `config outbound 'mysub2'\n` +
      `\toption type 'subscription'\n` +
      `\toption sub_url 'https://sub.example.com/y'\n`;
    await putFile(uciCfg, `${dir}/config/singbox-ui`);

    const probe = `
let sub = require("subscription");
let captured = [];
sub._set_fetcher_for_test(function(jobs){
  for (let j in jobs)
    push(captured, { name:j.name, url:j.url, ua:j.ua,
                     has_cfg:(exists(j, "cfg_json")) });
  let fs = require("fs");
  for (let j in jobs) { let f = fs.open(j.body_path,"w"); f.write("trojan://x@h:1#n\\n"); f.close(); }
});
let uci = require("uci").cursor(getenv("UCI_CONFIG_DIR"));
sub._cmd_fetch_subs_for_test(uci);
print(sprintf("%J", captured));
`;
    const probePath = `${dir}/probe.uc`;
    await putFile(probe, probePath);

    const r = await runProbe(probePath, {
      UCI_CONFIG_DIR: `${dir}/config`,
      SINGBOX_TMPDIR: `${dir}/tmp`,
    });

    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);
    const cap = JSON.parse(r.stdout) as Array<{
      name: string;
      url: string;
      ua: string;
      has_cfg: boolean;
    }>;

    const job1 = cap.find((j) => j.url.includes("sub.example.com/x"));
    expect(job1).toBeDefined();
    expect(job1!.ua).toContain("v2rayNG");
    expect(job1!.has_cfg).toBe(false);

    // mysub2 also picked up
    const job2 = cap.find((j) => j.url.includes("sub.example.com/y"));
    expect(job2).toBeDefined();
  });

  it("Test B: _build_fetch_config_for_test seam is removed", async () => {
    const probe = `
let sub = require("subscription");
print(exists(sub, "_build_fetch_config_for_test") ? "present" : "absent");
`;
    const dir = `/tmp/sbfetch-b-${Date.now()}`;
    await exec(`mkdir -p ${dir}`);
    const probePath = `${dir}/probe.uc`;
    await putFile(probe, probePath);
    const r = await runProbe(probePath);
    await exec(`rm -rf ${dir}`);
    expect(r.exitCode).toBe(0);
    expect(r.stdout.trim()).toBe("absent");
  });

  it("Test C: _fetcher_real invokes curl with url/ua as single argv tokens and --max-time", async () => {
    const dir = `/tmp/sbfetch-c-${Date.now()}`;
    await exec(`mkdir -p ${dir}`);

    // The curl-recording stub: writes each arg on its own line to ARGV_LOG,
    // then writes a minimal body to the -o target so downstream parsing succeeds.
    const recScript =
      `#!/bin/sh\n` +
      `printf '%s\\n' "$@" >> "$ARGV_LOG"\n` +
      `out=""; prev=""\n` +
      `for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done\n` +
      `[ -n "$out" ] && printf 'trojan://x@h:1#n\\n' > "$out"\n` +
      `exit 0\n`;
    const recPath = `${dir}/curl-rec.sh`;
    await putFile(recScript, recPath);
    await exec(`chmod +x ${recPath}`);

    const argvLog = `${dir}/argv.log`;
    await exec(`touch ${argvLog}`);

    const probe = `
let sub = require("subscription");
sub._fetcher_real_for_test([
  { name:"s1", url:"https://h/x?a=1&b=2", ua:"Custom UA/1.0",
    hdr_path:"${dir}/s1.hdr", body_path:"${dir}/s1.body", opts:{timeout:9} },
  { name:"s2", url:"https://h/y", ua:"",
    hdr_path:"${dir}/s2.hdr", body_path:"${dir}/s2.body", opts:{timeout:9} },
]);
`;
    const probePath = `${dir}/probeC.uc`;
    await putFile(probe, probePath);

    const r = await runProbe(probePath, {
      CURL: recPath,
      ARGV_LOG: argvLog,
    });

    // Read the recorded argv log
    const logR = await exec(`cat ${argvLog}`);
    await exec(`rm -rf ${dir}`);

    expect(r.exitCode).toBe(0);

    const lines = logR.stdout.split("\n");

    // url with query-string params must be a single token (not split on & or space)
    expect(lines).toContain("https://h/x?a=1&b=2");

    // custom UA must be a single token
    expect(lines).toContain("Custom UA/1.0");

    // empty UA must fall back to the DEFAULT_UA (Chrome string)
    const hasDefaultUA = lines.some((l) =>
      l.includes("Mozilla/5.0") && l.includes("Chrome"),
    );
    expect(hasDefaultUA).toBe(true);

    // --max-time flag must be present
    expect(lines).toContain("--max-time");
  });
});
