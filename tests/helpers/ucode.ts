import { type ExecResult, exec, putFile } from "./ssh.ts";

const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

let counter = 0;

function shquote(a: string): string {
  return `'${a.replace(/'/g, "'\\''")}'`;
}

// Run an inline ucode snippet: write a temp .uc into the guest, run it with
// the production -L lib path, clean up, propagate the real exit code.
// extraLibDirs: additional -L paths appended after the default LIB (e.g.
// ["tests/parity"] for require("corpus") in parity drivers).
// env: extra environment for the guest process (e.g. the UCI_CONFIG_DIR that
// pluginsEnabledUci() below hands back).
export async function runUcode(
  src: string,
  args: string[] = [],
  extraLibDirs: string[] = [],
  env: Record<string, string> = {},
): Promise<ExecResult> {
  const remote = `/tmp/sb-ucode-${process.pid}-${counter++}.uc`;
  const put = await putFile(src, remote);
  if (put.exitCode !== 0) throw new Error(`putFile failed: ${put.stderr}`);
  const libs = [LIB, ...extraLibDirs].map((d) => `-L ${d}`).join(" ");
  const argstr = args.map(shquote).join(" ");
  const envstr = Object.entries(env)
    .map(([k, v]) => `${k}=${shquote(v)}`)
    .join(" ");
  return exec(
    `cd ${WORK} && ${envstr} ucode ${libs} ${remote} ${argstr}; rc=$?; rm -f ${remote}; exit $rc`,
  );
}

// Seed a guest UCI tree whose `plugins` section switches the named plugins ON,
// and return it as an env record for runUcode/exec. Plugin hooks (rpcd methods,
// lifecycle, nft fragments, on_generate_post) only take effect for a plugin whose
// singbox-ui.plugins.<name>_enabled is "1" — unset means off, exactly as the UI
// reports it — so any test that exercises a hook has to switch its plugin on.
export async function pluginsEnabledUci(
  names: string[],
): Promise<Record<string, string>> {
  const dir = `/tmp/sb-plug-uci-${process.pid}-${counter++}`;
  const lines = ["config singbox-ui 'plugins'"].concat(
    names.map((n) => `\toption ${n}_enabled '1'`),
  );
  const r = await exec(`mkdir -p ${dir}`);
  if (r.exitCode !== 0) throw new Error(`mkdir failed: ${r.stderr}`);
  const put = await putFile(`${lines.join("\n")}\n`, `${dir}/singbox-ui`);
  if (put.exitCode !== 0) throw new Error(`putFile failed: ${put.stderr}`);
  return { UCI_CONFIG_DIR: dir };
}

export async function runUcodeJSON<T = unknown>(
  src: string,
  args: string[] = [],
  extraLibDirs: string[] = [],
  env: Record<string, string> = {},
): Promise<T> {
  const r = await runUcode(src, args, extraLibDirs, env);
  if (r.exitCode !== 0) {
    throw new Error(
      `ucode exit ${r.exitCode}\nstderr: ${r.stderr}\nstdout: ${r.stdout}`,
    );
  }
  return JSON.parse(r.stdout) as T;
}
