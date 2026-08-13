// Grok CLI sessions.
//
// Grok writes no status file, so a running session is found by process: `ps`
// for grok processes, then `lsof` to learn which events.jsonl each one holds
// open. That transcript's last turn marker says whether it is still working.

import { execFile } from "node:child_process";
import { readdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join } from "node:path";
import { promisify } from "node:util";
import { reversedRecords } from "./jsonl.js";
import { claudeAcpLinks, externalParent, linkKey } from "./parent-links.js";

const execFileAsync = promisify(execFile);
const PROCESS_TIMEOUT_MS = 1_000;
const GROK_LINK_SCAN_LIMIT = 400;

async function runCommand(command, args) {
  try {
    const { stdout } = await execFileAsync(command, args, {
      timeout: PROCESS_TIMEOUT_MS,
      maxBuffer: 4 * 1024 * 1024
    });
    return stdout;
  } catch (error) {
    // `ps`/`lsof` exit nonzero when a pid vanished mid-call; partial output is
    // still usable, and a hard failure just means no grok sessions this pass.
    return typeof error?.stdout === "string" ? error.stdout : "";
  }
}

export async function lastGrokTurn(path) {
  for await (const record of reversedRecords(path)) {
    if (record?.type === "turn_started" || record?.type === "turn_ended") return record.type;
  }
  return null;
}

/** Gateway worker links recorded in a grok CLI session's own logs. */
export async function grokAcpLinks(sessionDirectory, limit = GROK_LINK_SCAN_LIMIT) {
  const links = [];
  for (const name of ["updates.jsonl", "chat_history.jsonl"]) {
    let index = 0;
    for await (const record of reversedRecords(join(sessionDirectory, name))) {
      if (index >= limit) break;
      index += 1;
      const dumped = JSON.stringify(record);
      // "agent_acp" is the tool_name grok records for a real gateway call —
      // proof this is a response rather than quoted text.
      if (dumped.includes("acpSessionId") && dumped.includes("agent_acp")) {
        links.push(...claudeAcpLinks(dumped.replaceAll('\\"', '"')));
      }
    }
    if (links.length) break;
  }
  return links;
}

/** Attributes gateway workers to the grok CLI session that launched them. */
export async function recordGrokAcpLinks(states, parents, now, grokRoot = null) {
  if (!parents) return false;
  const root = grokRoot ?? join(homedir(), ".grok", "sessions");
  let changed = false;
  for (const item of Object.values(states)) {
    if (item?.provider !== "grok") continue;
    const link = item.link_session ?? item.session;
    let directories;
    try {
      directories = await readdir(root, { withFileTypes: true });
    } catch {
      return changed;
    }
    for (const entry of directories) {
      if (!entry.isDirectory()) continue;
      const candidate = join(root, entry.name, link);
      try {
        if (!(await stat(candidate)).isDirectory()) continue;
      } catch {
        continue;
      }
      for (const [provider, acpSession] of await grokAcpLinks(candidate)) {
        if (acpSession === link) continue;
        const key = linkKey(provider, acpSession);
        if (parents.get(key)?.[0] !== link) {
          parents.set(key, [link, now]);
          changed = true;
        }
      }
      break;
    }
  }
  return changed;
}

export function isGrokProcess(command, args) {
  const executable = args ? args.split(/\s+/, 1)[0] : command;
  return basename(command ?? "") === "grok" || basename(executable ?? "") === "grok";
}

/** How long a cached pid→events.jsonl mapping is trusted before re-checking. */
const EVENT_PATH_REFRESH_SECONDS = 60;

/**
 * Maps grok pids to the events.jsonl each one holds open.
 *
 * `cache` (pid -> {path, at}) makes lsof incremental: a process's open
 * transcript is stable for its lifetime, and lsof measures ~40ms CPU per call
 * — on a machine with long-lived grok processes that was the single largest
 * steady-state cost of the whole scanner (~2% of a core at the 2s cadence).
 * Only unseen pids are queried; cached entries are re-verified on a slow
 * refresh as a safety net, and dead pids fall out of the cache.
 */
export async function grokEventPaths(pids, cache = null, now = Date.now() / 1000) {
  if (!pids.length) {
    cache?.clear();
    return new Map();
  }
  const paths = new Map();
  let stale = pids;
  if (cache) {
    for (const pid of [...cache.keys()]) {
      if (!pids.includes(pid)) cache.delete(pid);
    }
    stale = pids.filter((pid) => {
      const entry = cache.get(pid);
      if (entry && now - entry.at < EVENT_PATH_REFRESH_SECONDS) {
        if (entry.path) paths.set(pid, entry.path);
        return false;
      }
      return true;
    });
    if (!stale.length) return paths;
  }

  const stdout = await runCommand("lsof", ["-a", "-p", stale.join(","), "-Fn"]);
  const found = new Set();
  let pid = null;
  for (const line of stdout.split("\n")) {
    if (line.startsWith("p")) {
      const parsed = Number.parseInt(line.slice(1), 10);
      pid = Number.isInteger(parsed) ? parsed : null;
    } else if (pid != null && line.startsWith("n") && line.endsWith("/events.jsonl")) {
      paths.set(pid, line.slice(1));
      cache?.set(pid, { path: line.slice(1), at: now });
      found.add(pid);
    }
  }
  // A queried pid with no open events.jsonl is also worth remembering, so a
  // non-transcript grok process doesn't get re-lsof'd every pass.
  for (const staleId of stale) {
    if (!found.has(staleId)) cache?.set(staleId, { path: null, at: now });
  }
  return paths;
}

export async function cliProcessStates(processes, eventPaths, now, previous = {}, parents = null) {
  // A grok launched through the ACP proxy is a gateway worker, not a local
  // session; the gateway already reports it.
  const isProxied = (pid) => {
    const seen = new Set();
    let current = pid;
    while (processes.has(current) && !seen.has(current)) {
      seen.add(current);
      const [parent, , args] = processes.get(current);
      if (args.includes("pet_acp_proxy.py")) return true;
      current = parent;
    }
    return false;
  };

  const states = {};
  for (const [pid, [, command, args]] of processes) {
    const eventPath = eventPaths.get(pid);
    if (!isGrokProcess(command, args) || isProxied(pid) || !eventPath) continue;
    if (await lastGrokTurn(eventPath) !== "turn_started") continue;
    const session = `grok-cli-${pid}`;
    const sessionDirectory = dirname(eventPath);
    states[session] = {
      provider: "grok",
      session,
      state: "running",
      event: "process/running",
      time: previous[session]?.time ?? now,
      pid,
      parent: externalParent(parents ?? new Map(), "grok", basename(sessionDirectory)),
      engine: "grok-cli",
      cwd: decodeURIComponent(basename(dirname(sessionDirectory))),
      link_session: basename(sessionDirectory)
    };
  }
  return states;
}

export async function detectCliProcesses(now, previous = {}, parents = null, eventPathCache = null) {
  const stdout = await runCommand("ps", ["-axo", "pid=,ppid=,comm=,args="]);
  if (!stdout) return previous;
  const processes = new Map();
  for (const line of stdout.split("\n")) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 4) continue;
    const pid = Number.parseInt(fields[0], 10);
    const ppid = Number.parseInt(fields[1], 10);
    if (!Number.isInteger(pid) || !Number.isInteger(ppid)) continue;
    const command = fields[2];
    const args = line.trim().split(/\s+/).slice(3).join(" ");
    processes.set(pid, [ppid, command, args]);
  }
  const grokPids = [...processes]
    .filter(([, [, command, args]]) => isGrokProcess(command, args))
    .map(([pid]) => pid);
  return cliProcessStates(processes, await grokEventPaths(grokPids, eventPathCache, now), now, previous, parents);
}
