import { spawn } from "node:child_process";

export async function updateSourceCheckout(root, { run = runSourceCommand } = {}) {
  const repository = await requireSuccess(run, "git", ["rev-parse", "--is-inside-work-tree"], root, "locate the Git checkout");
  if (repository.stdout.trim() !== "true") throw new Error("ACP Gateway source is not inside a Git worktree");

  const status = await requireSuccess(run, "git", ["status", "--porcelain"], root, "inspect local source changes");
  if (status.stdout.trim()) {
    throw new Error("ACP Gateway source has local changes; commit or stash them before --update");
  }

  const pull = await requireSuccess(run, "git", ["pull", "--ff-only"], root, "update ACP Gateway source");
  const install = await requireSuccess(run, "npm", ["ci"], root, "install ACP Gateway dependencies");
  return {
    root,
    pull: pull.stdout.trim() || pull.stderr.trim(),
    dependencies: install.stdout.trim() || install.stderr.trim()
  };
}

export function runSourceCommand(command, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

async function requireSuccess(run, command, args, cwd, action) {
  const result = await run(command, args, cwd);
  if (result.code === 0) return result;
  throw new Error(`${action} failed: ${(result.stderr || result.stdout || `${command} exited ${result.code}`).trim()}`);
}
