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
export async function runUcode(
  src: string,
  args: string[] = [],
  extraLibDirs: string[] = [],
): Promise<ExecResult> {
  const remote = `/tmp/sb-ucode-${process.pid}-${counter++}.uc`;
  const put = await putFile(src, remote);
  if (put.exitCode !== 0) throw new Error(`putFile failed: ${put.stderr}`);
  const libs = [LIB, ...extraLibDirs].map((d) => `-L ${d}`).join(" ");
  const argstr = args.map(shquote).join(" ");
  return exec(
    `cd ${WORK} && ucode ${libs} ${remote} ${argstr}; rc=$?; rm -f ${remote}; exit $rc`,
  );
}

export async function runUcodeJSON<T = unknown>(
  src: string,
  args: string[] = [],
  extraLibDirs: string[] = [],
): Promise<T> {
  const r = await runUcode(src, args, extraLibDirs);
  if (r.exitCode !== 0) {
    throw new Error(
      `ucode exit ${r.exitCode}\nstderr: ${r.stderr}\nstdout: ${r.stdout}`,
    );
  }
  return JSON.parse(r.stdout) as T;
}

// Prod-path tests (shebang-sensitive): run an in-tree file directly so the
// shebang `-L` resolution is exercised, NOT inline `ucode -L`.
export function runUcodeFile(
  remoteRelPath: string,
  args: string[] = [],
): Promise<ExecResult> {
  const argstr = args.map(shquote).join(" ");
  return exec(`cd ${WORK} && ucode -L ${LIB} ${remoteRelPath} ${argstr}`);
}
