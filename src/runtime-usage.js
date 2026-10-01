// What still uses an installed runtime version, and how much disk it holds.
//
// A version that is neither current nor previous can still be live: an agent
// MCP entry pinned to runtime/versions/<id>/ launches it on every new session,
// and an already running daemon, Control or guide process executes from it.
// Pruning such a version breaks the entry (or the next restart of the
// process), so prune keeps it and says why instead.

import { execFile } from "node:child_process";
import { lstat, readdir, readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, sep } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

/** Agent configs that register Gateway MCP entries. */
export function defaultAgentConfigPaths(env = process.env, home = homedir()) {
  return [
    join(home, ".claude.json"),
    join(env.CODEX_HOME || join(home, ".codex"), "config.toml"),
    join(env.GROK_HOME || join(home, ".grok"), "config.toml"),
    join(env.AUGMENT_HOME || join(home, ".augment"), "settings.json")
  ];
}

async function runningCommands() {
  try {
    const { stdout } = await execFileAsync("ps", ["-axo", "command="], { maxBuffer: 16 * 1024 * 1024 });
    return stdout.split("\n");
  } catch {
    return [];
  }
}

/** Version ids named as `<versionsRoot>/<id>/...` anywhere in `text`. */
function referencedIds(text, versionsRoot) {
  const prefix = versionsRoot.endsWith(sep) ? versionsRoot : versionsRoot + sep;
  const ids = new Set();
  let index = text.indexOf(prefix);
  while (index !== -1) {
    const id = /^[^/\\"'\s]+/.exec(text.slice(index + prefix.length))?.[0];
    if (id) ids.add(id);
    index = text.indexOf(prefix, index + prefix.length);
  }
  return ids;
}

/**
 * versionId -> reasons ("config:<path>", "process:<pid or command>") for every
 * version an agent config or a running process still references.
 */
export async function runtimeVersionsInUse(versionsRoot, {
  configPaths = defaultAgentConfigPaths(),
  commands = null
} = {}) {
  const usage = new Map();
  const add = (id, reason) => {
    if (!usage.has(id)) usage.set(id, []);
    if (!usage.get(id).includes(reason)) usage.get(id).push(reason);
  };
  for (const path of configPaths) {
    let text;
    try {
      text = await readFile(path, "utf8");
    } catch {
      continue;
    }
    for (const id of referencedIds(text, versionsRoot)) add(id, `config:${path}`);
  }
  for (const command of commands ?? await runningCommands()) {
    for (const id of referencedIds(command, versionsRoot)) add(id, "process");
  }
  return usage;
}

/** Bytes a directory tree holds on disk, symlinks counted as links. */
export async function directoryBytes(path) {
  let total = 0;
  const pending = [path];
  while (pending.length) {
    const current = pending.pop();
    let stats;
    try {
      stats = await lstat(current);
    } catch {
      continue;
    }
    // Allocated blocks, so sparse or cloned files are not overcounted.
    total += stats.blocks ? stats.blocks * 512 : stats.size;
    if (!stats.isDirectory()) continue;
    try {
      for (const name of await readdir(current)) pending.push(join(current, name));
    } catch {
      // An unreadable subtree just counts as what was reachable.
    }
  }
  return total;
}
