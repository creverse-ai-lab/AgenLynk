// Grok CLI sessions.
//
// Grok writes no status file, so a running session is found by process: `ps`
// for grok processes, then `lsof` to learn which events.jsonl each one holds
// open. That transcript's last turn marker says whether it is still working.

import { execFile } from "node:child_process";
import { readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
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

export function isProxiedGrokProcess(processes, pid) {
  const seen = new Set();
  let current = pid;
  while (processes.has(current) && !seen.has(current)) {
    seen.add(current);
    const [parent, , args] = processes.get(current);
    if (args.includes("pet_acp_proxy.py")) return true;
    current = parent;
  }
  return false;
}

export function isMultiplexedGrokProcess(command, args) {
  return isGrokProcess(command, args) && /\bagent\s+stdio\b/.test(args);
}

/** How long cached pid→events.jsonl mappings are trusted before re-checking. */
const EVENT_PATH_REFRESH_SECONDS = 60;
const EMPTY_EVENT_PATH_REFRESH_SECONDS = 5;

/** Parses every events.jsonl held by each pid from lsof's field output. */
export function parseGrokEventPaths(stdout, allowedPaths = null) {
  const paths = new Map();
  let pid = null;
  for (const line of stdout.split("\n")) {
    if (line.startsWith("p")) {
      const parsed = Number.parseInt(line.slice(1), 10);
      pid = Number.isInteger(parsed) ? parsed : null;
    } else if (pid != null && line.startsWith("n") && line.endsWith("/events.jsonl")) {
      const path = resolve(line.slice(1));
      if (allowedPaths && !allowedPaths.has(path)) continue;
      const current = paths.get(pid) ?? [];
      if (!current.includes(path)) current.push(path);
      paths.set(pid, current);
    }
  }
  return paths;
}

/**
 * Exact Grok transcript candidates. The layout is fixed at
 * <encoded-cwd>/<session>/events.jsonl, so there is no reason to inspect any
 * other file held open by the Grok process or recurse into project folders.
 */
export async function grokTranscriptPaths(root, now = Date.now() / 1000, staleAfter = 600) {
  const paths = [];
  let workspaces;
  try {
    workspaces = await readdir(root, { withFileTypes: true });
  } catch {
    return paths;
  }
  for (const workspace of workspaces) {
    if (!workspace.isDirectory()) continue;
    const workspacePath = join(root, workspace.name);
    let sessions;
    try {
      sessions = await readdir(workspacePath, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const session of sessions) {
      if (!session.isDirectory()) continue;
      const candidate = resolve(workspacePath, session.name, "events.jsonl");
      try {
        const canonical = await realpath(candidate);
        const modified = (await stat(canonical)).mtimeMs / 1000;
        if (now - modified <= staleAfter) paths.push(canonical);
      } catch {
        // A partially created or already removed session is not a candidate.
      }
    }
  }
  return paths;
}

export function grokLsofArgs(pids, transcriptPaths) {
  return ["-a", "-p", pids.join(","), "-Fn", "--", ...transcriptPaths];
}

/**
 * Maps grok pids to the events.jsonl each one holds open.
 *
 * `cache` (pid -> {paths, at}) makes lsof incremental for interactive Grok
 * processes, whose open transcript is normally stable for their lifetime.
 * The ACP `agent stdio` process is multiplexed and bypasses this cache in
 * detectCliProcesses because it can open another session at any time.
 */
export async function grokEventPaths(
  pids,
  cache = null,
  now = Date.now() / 1000,
  grokRoot = join(homedir(), ".grok", "sessions"),
  staleAfter = 600
) {
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
      const cachedPaths = entry?.paths ?? (entry?.path ? [entry.path] : []);
      const refreshAfter = cachedPaths.length
        ? EVENT_PATH_REFRESH_SECONDS
        : EMPTY_EVENT_PATH_REFRESH_SECONDS;
      if (entry && now - entry.at < refreshAfter) {
        if (cachedPaths.length) paths.set(pid, cachedPaths);
        return false;
      }
      return true;
    });
    if (!stale.length) return paths;
  }

  const candidates = await grokTranscriptPaths(grokRoot, now, staleAfter);
  const allowedPaths = new Set(candidates);
  const stdout = candidates.length
    ? await runCommand("lsof", grokLsofArgs(stale, candidates))
    : "";
  const discovered = parseGrokEventPaths(stdout, allowedPaths);
  for (const [pid, pidPaths] of discovered) {
    paths.set(pid, pidPaths);
    cache?.set(pid, { paths: pidPaths, at: now });
  }
  // A queried pid with no open events.jsonl is also worth remembering, so a
  // non-transcript grok process doesn't get re-lsof'd every pass.
  for (const staleId of stale) {
    if (!discovered.has(staleId)) cache?.set(staleId, { paths: [], at: now });
  }
  return paths;
}

export async function cliProcessStates(processes, eventPaths, now, previous = {}, parents = null) {
  // A grok launched through the ACP proxy is a gateway worker, not a local
  // session; the gateway already reports it.
  const states = {};
  for (const [pid, [, command, args]] of processes) {
    const values = eventPaths.get(pid);
    const candidates = Array.isArray(values) ? values : values ? [values] : [];
    if (!isGrokProcess(command, args) || isProxiedGrokProcess(processes, pid) || !candidates.length) continue;
    for (const eventPath of candidates) {
      if (await lastGrokTurn(eventPath) !== "turn_started") continue;
      const sessionDirectory = dirname(eventPath);
      // The provider-side id is stable across pid reuse and matches the
      // Gateway's acpSessionId, allowing mergeMonitorSessions to dedupe a
      // Gateway-owned worker while still exposing an independent local CLI.
      const session = basename(sessionDirectory);
      const stateKey = `grok:${session}`;
      states[stateKey] = {
        provider: "grok",
        session,
        state: "running",
        event: "process/running",
        time: previous[stateKey]?.time ?? now,
        pid,
        parent: externalParent(parents ?? new Map(), "grok", session),
        engine: "grok-cli",
        cwd: decodeURIComponent(basename(dirname(sessionDirectory))),
        link_session: session
      };
    }
  }
  return states;
}

export async function detectCliProcesses(
  now,
  previous = {},
  parents = null,
  eventPathCache = null,
  grokRoot = join(homedir(), ".grok", "sessions"),
  staleAfter = 600
) {
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
    .filter(([pid, [, command, args]]) =>
      isGrokProcess(command, args) && !isProxiedGrokProcess(processes, pid))
    .map(([pid]) => pid);
  // The ACP adapter keeps one long-lived `grok agent stdio` process and opens
  // new transcript files as sessions are created. Its pid alone cannot make a
  // cached fd list safe, so refresh only these multiplexed processes each pass.
  for (const [pid, [, command, args]] of processes) {
    if (isMultiplexedGrokProcess(command, args) && !isProxiedGrokProcess(processes, pid)) {
      eventPathCache?.delete(pid);
    }
  }
  return cliProcessStates(
    processes,
    await grokEventPaths(grokPids, eventPathCache, now, grokRoot, staleAfter),
    now,
    previous,
    parents
  );
}
