// A daemon started before a token rotation accepts only the identity it
// started with, so it refuses daemon_shutdown from a monitor that already
// holds the new token. Gateway 1.8 says to end it with SIGTERM to the pid in
// `<socket>.lock`; only a process whose command line runs the Gateway daemon
// is signalled, so a stale lock whose pid another process reuses is left be.
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const DAEMON_ENTRY = /\/gateway-daemon\.js(?:\s|$)/;

/** Whether `command` (a ps command line) runs the Gateway daemon. */
export function runsGatewayDaemon(command) {
  return DAEMON_ENTRY.test(String(command ?? ""));
}

/** Sends SIGTERM to the daemon named by `<socketPath>.lock`; true when one was signalled. */
export async function terminateLockedDaemon(socketPath, {
  readLock = (path) => readFile(path, "utf8"),
  commandOf = async (pid) => (await execFileAsync("ps", ["-o", "command=", "-p", String(pid)])).stdout,
  kill = (pid, signal) => process.kill(pid, signal)
} = {}) {
  const pid = Number(String(await readLock(`${socketPath}.lock`).catch(() => "")).trim());
  if (!Number.isInteger(pid) || pid <= 1 || pid === process.pid) return false;
  const command = await commandOf(pid).catch(() => "");
  if (!runsGatewayDaemon(command)) return false;
  try {
    kill(pid, "SIGTERM");
    return true;
  } catch {
    return false;
  }
}
