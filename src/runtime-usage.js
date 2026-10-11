// What still uses an installed runtime version, and how much disk it holds.
//
// A version that is neither current nor previous can still be live: an agent
// MCP entry pinned to runtime/versions/<id>/ launches it on every new session,
// and an already running daemon, Control or guide process executes from it.
// Pruning such a version breaks the entry (or the next restart of the
// process), so prune keeps it and says why instead.

import { execFile } from "node:child_process";
import { lstat, readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, sep } from "node:path";
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

/** Seconds in a `ps` elapsed time, `[[dd-]hh:]mm:ss`; null when it does not parse. */
export function elapsedSeconds(etime) {
  const match = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(String(etime ?? "").trim());
  if (!match) return null;
  const [, days = 0, hours = 0, minutes, seconds] = match;
  return ((Number(days) * 24 + Number(hours)) * 60 + Number(minutes)) * 60 + Number(seconds);
}

/**
 * Processes whose command line names the runtime root, with when they
 * started and the executable they really run (the kernel's path, through
 * any `current` link), for the processes that name no version themselves.
 */
async function runningRuntimeProcesses(runtimeRoot, now = Date.now()) {
  let stdout = "";
  try {
    ({ stdout } = await execFileAsync("ps", ["-axo", "pid=,etime=,command="], { maxBuffer: 16 * 1024 * 1024 }));
  } catch {
    return [];
  }
  const processes = [];
  for (const line of stdout.split("\n")) {
    const match = /^\s*(\d+)\s+(\S+)\s+(.*)$/.exec(line);
    if (!match || !match[3].includes(runtimeRoot)) continue;
    const elapsed = elapsedSeconds(match[2]);
    let executable = null;
    if (match[3].includes(join(runtimeRoot, "current") + sep)) {
      try {
        const { stdout: files } = await execFileAsync("lsof", ["-a", "-p", match[1], "-d", "txt", "-Fn"]);
        executable = files.split("\n").find((item) => item.startsWith("n"))?.slice(1) ?? null;
      } catch {
        executable = null;
      }
    }
    processes.push({
      pid: Number(match[1]),
      startedAtMs: elapsed == null ? null : now - elapsed * 1000,
      command: match[3],
      executable
    });
  }
  return processes;
}

/**
 * versionId -> reasons ("config:<path>", "process:<pid or command>") for every
 * version an agent config or a running process still references.
 *
 * A process started through `<runtimeRoot>/current/` names no version: an
 * agent CLI's front door runs on from whatever `current` was when the CLI
 * started, and loses its code if that version is removed under it. Its real
 * executable says which version when it is the runtime's own Node. Under
 * another Node it runs the current version if it started after the current
 * one was activated; started before, any version installed by then may be
 * its, and all of those are kept until it exits.
 */
export async function runtimeVersionsInUse(versionsRoot, {
  configPaths = defaultAgentConfigPaths(),
  commands = null,
  processes = null,
  now = Date.now()
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
  const runtimeRoot = dirname(versionsRoot);
  const live = processes ?? (commands ? null : await runningRuntimeProcesses(runtimeRoot, now));
  for (const command of commands ?? (live ?? []).map((item) => item.command)) {
    for (const id of referencedIds(command, versionsRoot)) add(id, "process");
  }
  const throughCurrent = (live ?? []).filter((item) => item.command.includes(join(runtimeRoot, "current") + sep));
  if (throughCurrent.length) {
    let activatedAtMs = null;
    try {
      activatedAtMs = Date.parse(JSON.parse(await readFile(join(runtimeRoot, "current.json"), "utf8")).activatedAt) || null;
    } catch {
      activatedAtMs = null;
    }
    let installed = null;
    for (const item of throughCurrent) {
      const exact = item.executable ? [...referencedIds(item.executable, versionsRoot)] : [];
      if (exact.length) {
        for (const id of exact) add(id, `process:${item.pid}`);
        continue;
      }
      if (activatedAtMs != null && item.startedAtMs != null && item.startedAtMs >= activatedAtMs) continue;
      installed ??= await installedVersions(versionsRoot);
      for (const version of installed) {
        if (item.startedAtMs == null || version.installedAtMs <= item.startedAtMs) {
          add(version.id, `process:${item.pid} (started before the current runtime)`);
        }
      }
    }
  }
  return usage;
}

/** Each installed version with when its directory was made. */
async function installedVersions(versionsRoot) {
  let entries = [];
  try {
    entries = await readdir(versionsRoot, { withFileTypes: true });
  } catch {
    return [];
  }
  const versions = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    try {
      const info = await stat(join(versionsRoot, entry.name));
      versions.push({ id: entry.name, installedAtMs: info.birthtimeMs || info.mtimeMs });
    } catch {
      // gone meanwhile
    }
  }
  return versions;
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
