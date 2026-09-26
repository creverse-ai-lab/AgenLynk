// Where agent hooks find the running sidecar: a 0600 file holding the port
// and a per-launch token, rewritten on every sidecar start. The hook script
// (sidecar/hooks/agenlynk-hook.sh) parses it; it is never sourced.

import { randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export function agenlynkHome(env = process.env) {
  return env.AGENLYNK_HOME || join(homedir(), ".acp-gateway", "agenlynk");
}

export function defaultHookEndpointPath(env = process.env) {
  return env.AGENLYNK_HOOK_ENDPOINT || join(agenlynkHome(env), "hook-endpoint");
}

export function newHookToken() {
  return randomBytes(24).toString("base64url");
}

export function writeHookEndpoint(path, { port, token }) {
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  writeFileSync(temporary, `AGENLYNK_HOOK_PORT=${port}\nAGENLYNK_HOOK_TOKEN=${token}\n`, { mode: 0o600 });
  renameSync(temporary, path);
  chmodSync(path, 0o600);
}

/** Removes the file only if it still names this sidecar's token. */
export function removeHookEndpoint(path, token) {
  try {
    if (readFileSync(path, "utf8").includes(`AGENLYNK_HOOK_TOKEN=${token}\n`)) rmSync(path, { force: true });
  } catch {
    // Already gone or replaced by a newer sidecar.
  }
}
