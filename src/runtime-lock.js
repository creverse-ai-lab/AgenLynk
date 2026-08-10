// Advisory cross-process lock over a runtime root's mutations.
//
// stage/activate/rollback/prune and the first-install path all rewrite
// directories under the same runtime root, and they have three live entry
// points that can genuinely overlap: the provisioner CLI on app launch, the
// updater CLI from the Settings screen, and the monitor's HTTP surface — with
// nothing stopping two app instances either. Unsynchronized, two stages of
// the same version interleave rm/rename into a spurious failure, and a stage
// racing an activate can leave current.json pointing at a directory that was
// just removed.
//
// mkdir is the lock primitive because it is atomic on every filesystem Node
// supports and needs no native flock binding. Staleness handles a holder that
// died without cleanup: mutations finish in seconds, so a lock directory
// older than the threshold cannot belong to a live operation.

import { mkdir, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";

const LOCK_DIRECTORY_NAME = ".runtime-mutation.lock";
const STALE_LOCK_MS = 10 * 60 * 1000;

export class RuntimeLockBusyError extends Error {
  constructor(lockPath) {
    super(`another runtime operation is in progress (${lockPath})`);
    this.code = "UPDATER_BUSY";
  }
}

/**
 * Runs `operation` while holding the runtime root's mutation lock.
 * Throws RuntimeLockBusyError (code UPDATER_BUSY) when another live process
 * holds it; a stale lock from a dead holder is reclaimed.
 */
export async function withRuntimeLock(runtimeRoot, operation) {
  await mkdir(runtimeRoot, { recursive: true });
  const lockPath = join(runtimeRoot, LOCK_DIRECTORY_NAME);
  try {
    await mkdir(lockPath);
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    let age = 0;
    try {
      age = Date.now() - (await stat(lockPath)).mtimeMs;
    } catch {
      // The holder released between our mkdir and stat; retry once.
      return withRuntimeLock(runtimeRoot, operation);
    }
    if (age < STALE_LOCK_MS) throw new RuntimeLockBusyError(lockPath);
    // Reclaim: remove the stale lock and race for a fresh one. If another
    // waiter wins the re-acquisition, this throws UPDATER_BUSY — correct.
    await rm(lockPath, { recursive: true, force: true });
    try {
      await mkdir(lockPath);
    } catch (retryError) {
      if (retryError?.code === "EEXIST") throw new RuntimeLockBusyError(lockPath);
      throw retryError;
    }
  }
  try {
    // Best-effort breadcrumb for a human inspecting a stuck lock.
    await writeFile(join(lockPath, "holder.json"), JSON.stringify({ pid: process.pid, at: new Date().toISOString() }));
  } catch {
    // The lock works without the breadcrumb.
  }
  try {
    return await operation();
  } finally {
    await rm(lockPath, { recursive: true, force: true }).catch(() => {});
  }
}
