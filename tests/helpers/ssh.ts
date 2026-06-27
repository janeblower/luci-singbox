import { spawn } from "node:child_process";
import { writeFile } from "node:fs/promises";

const HOST = process.env.SB_VM_HOST ?? "127.0.0.1";
const PORT = process.env.SB_VM_PORT ?? "2222";
const USER = process.env.SB_VM_USER ?? "root";
const PASS = process.env.SB_VM_PASS ?? "admin";
const SOCK = process.env.SB_VM_CTL ?? "/tmp/sb-cm.sock";

// When bun runs INSIDE the OpenWrt guest (VM lane sets SINGBOX_TESTS_IN_VM=1),
// the prod-path commands execute locally — no SSH. The exported API is
// identical so no test file changes.
const IN_GUEST = process.env.SINGBOX_TESTS_IN_VM === "1";

// Persistent connection via ControlMaster: the first `ssh` spawns a master,
// subsequent calls reuse the socket (near-zero handshake). ControlPersist
// self-reaps the master after idle, so no explicit warm/dispose is strictly
// required — but warmConnection() fails fast if the guest is down.
const SSH_OPTS = [
  "-o",
  "StrictHostKeyChecking=no",
  "-o",
  "UserKnownHostsFile=/dev/null",
  "-o",
  "LogLevel=ERROR",
  "-o",
  "ControlMaster=auto",
  "-o",
  `ControlPath=${SOCK}`,
  "-o",
  "ControlPersist=120",
  "-p",
  PORT,
];

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

function run(cmd: string, args: string[], input?: string): Promise<ExecResult> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ["pipe", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    p.stdout.on("data", (d) => (stdout += d));
    p.stderr.on("data", (d) => (stderr += d));
    p.on("error", reject);
    p.on("close", (code) => resolve({ stdout, stderr, exitCode: code ?? 0 }));
    if (input !== undefined) p.stdin.write(input);
    p.stdin.end();
  });
}

function sshpass(rest: string[]): string[] {
  return ["-p", PASS, "ssh", ...SSH_OPTS, `${USER}@${HOST}`, ...rest];
}

export function exec(remoteCmd: string): Promise<ExecResult> {
  if (IN_GUEST) return run("sh", ["-c", remoteCmd]);
  return run("sshpass", sshpass([remoteCmd]));
}

// scp is unavailable on the guest (no sftp-server) — pipe via cat (CLAUDE.md).
export async function putFile(
  content: string,
  remotePath: string,
): Promise<ExecResult> {
  if (IN_GUEST) {
    await writeFile(remotePath, content);
    return { stdout: "", stderr: "", exitCode: 0 };
  }
  return run("sshpass", sshpass([`cat > ${remotePath}`]), content);
}

export async function warmConnection(): Promise<void> {
  if (IN_GUEST) return;
  const r = await exec("true");
  if (r.exitCode !== 0) {
    throw new Error(
      `VM guest unreachable over ssh: ${r.stderr || `exit ${r.exitCode}`}`,
    );
  }
}

export async function closeConnection(): Promise<void> {
  if (IN_GUEST) return;
  await run("sshpass", [
    "-p",
    PASS,
    "ssh",
    "-o",
    `ControlPath=${SOCK}`,
    "-O",
    "exit",
    "-p",
    PORT,
    `${USER}@${HOST}`,
  ]).catch(() => {});
}
