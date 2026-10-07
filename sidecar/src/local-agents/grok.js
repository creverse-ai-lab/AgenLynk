// Grok CLI sessions.
//
// Grok writes no status file, so a running session is found by process: `ps`
// for grok processes, then `lsof` to learn which events.jsonl each one holds
// open. That transcript's last turn marker says whether it is still working.

import { readFile, readdir, realpath, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { reversedRecords } from "./jsonl.js";
import { headlessArgs, LINEAGE_ID, runCommand } from "./lineage.js";
import { externalParent, gatewayResponseLinks, linkKey } from "./parent-links.js";

const GROK_LINK_SCAN_LIMIT = 400;

export async function lastGrokTurn(path) {
  for await (const record of reversedRecords(path)) {
    if (record?.type === "turn_started" || record?.type === "turn_ended") return record.type;
  }
  return null;
}

/**
 * The output of a finished Gateway MCP call in a grok `updates.jsonl` record,
 * or null. Proof is structural: the record's own rawOutput names an agent_acp
 * tool on a Gateway server. chat_history.jsonl is not read for links: its
 * tool results carry no tool name, so a grep or file read that merely shows
 * gateway output would read as a response.
 */
function gatewayToolOutput(record) {
  const raw = (record?.params?.update ?? record?.update)?.rawOutput;
  const tool = String(raw?.tool_name ?? "");
  const server = String(raw?.server_name ?? "").toLowerCase();
  if (!tool.startsWith("agent_acp_") || !server.includes("acp") || server.includes("guide")) return null;
  return raw.output ?? null;
}

/** Gateway worker links recorded in a grok CLI session's own logs. */
export async function grokAcpLinks(sessionDirectory, limit = GROK_LINK_SCAN_LIMIT) {
  const links = [];
  let index = 0;
  for await (const record of reversedRecords(join(sessionDirectory, "updates.jsonl"))) {
    if (index >= limit) break;
    index += 1;
    const output = gatewayToolOutput(record);
    if (output) links.push(...gatewayResponseLinks(output));
  }
  return links;
}

const GROK_LINK_LOGS = ["updates.jsonl"];

/** size:mtime of the logs grokAcpLinks reads; null when the directory is gone. */
async function grokLinkFingerprint(sessionDirectory) {
  try {
    if (!(await stat(sessionDirectory)).isDirectory()) return null;
  } catch {
    return null;
  }
  const parts = [];
  for (const name of GROK_LINK_LOGS) {
    try {
      const metadata = await stat(join(sessionDirectory, name));
      parts.push(`${metadata.size}:${metadata.mtimeMs}`);
    } catch {
      parts.push("-");
    }
  }
  return parts.join("|");
}

/**
 * Attributes gateway workers to the grok CLI session that launched them.
 * `cache` (session -> {directory, fingerprint, links}) skips the directory
 * search and the log rescan while a session's logs are unchanged; discovery
 * runs every few seconds and the logs rarely grow between passes.
 */
export async function recordGrokAcpLinks(states, parents, now, grokRoot = null, cache = null) {
  if (!parents) return false;
  const root = grokRoot ?? join(homedir(), ".grok", "sessions");
  let changed = false;
  let directories = null;
  const current = new Set();
  for (const item of Object.values(states)) {
    if (item?.provider !== "grok") continue;
    const link = item.link_session ?? item.session;
    current.add(link);
    const cached = cache?.get(link) ?? null;
    let candidate = null;
    let fingerprint = cached ? await grokLinkFingerprint(cached.directory) : null;
    if (fingerprint != null) {
      candidate = cached.directory;
    } else {
      if (!directories) {
        try {
          directories = await readdir(root, { withFileTypes: true });
        } catch {
          return changed;
        }
      }
      for (const entry of directories) {
        if (!entry.isDirectory()) continue;
        const path = join(root, entry.name, link);
        try {
          if (!(await stat(path)).isDirectory()) continue;
        } catch {
          continue;
        }
        candidate = path;
        break;
      }
      if (!candidate) {
        cache?.delete(link);
        continue;
      }
      fingerprint = await grokLinkFingerprint(candidate);
    }
    const links = cached && cached.directory === candidate && cached.fingerprint === fingerprint
      ? cached.links
      : await grokAcpLinks(candidate);
    cache?.set(link, { directory: candidate, fingerprint, links });
    for (const [provider, acpSession] of links) {
      if (acpSession === link) continue;
      const key = linkKey(provider, acpSession);
      if (parents.get(key)?.[0] !== link) {
        parents.set(key, [link, now]);
        changed = true;
      }
    }
  }
  if (cache) for (const link of [...cache.keys()]) if (!current.has(link)) cache.delete(link);
  return changed;
}

/**
 * Sub-agent -> parent links Grok records in one workspace (encoded-cwd)
 * directory: a session that spawned a sub-agent keeps
 * `<parent>/subagents/<child>/meta.json`, and the child's own session sits
 * next to it. meta.json names both ids when it can be read; the directory
 * layout stands in when it cannot.
 */
export async function grokSubagentLinks(workspace) {
  const links = new Map();
  let sessions;
  try {
    sessions = await readdir(workspace, { withFileTypes: true });
  } catch {
    return links;
  }
  for (const session of sessions) {
    if (!session.isDirectory() || !LINEAGE_ID.test(session.name)) continue;
    let children;
    try {
      children = await readdir(join(workspace, session.name, "subagents"), { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of children) {
      if (!entry.isDirectory() || !LINEAGE_ID.test(entry.name)) continue;
      let parent = session.name;
      let child = entry.name;
      try {
        const meta = JSON.parse(await readFile(join(workspace, session.name, "subagents", entry.name, "meta.json"), "utf8"));
        if (typeof meta?.parent_session_id === "string" && LINEAGE_ID.test(meta.parent_session_id)) parent = meta.parent_session_id;
        if (typeof meta?.child_session_id === "string" && LINEAGE_ID.test(meta.child_session_id)) child = meta.child_session_id;
      } catch {
        // Not written yet or unreadable: the directory layout already names both.
      }
      if (child !== parent) links.set(child, parent);
    }
  }
  return links;
}

/**
 * Gives each Grok sub-agent session the Grok session that spawned it. This is
 * Grok's own record, so it wins over process lineage: a sub-agent runs inside
 * its parent's process and inherits that process's environment, which would
 * otherwise attribute it to whatever launched the parent.
 *
 * Links are cached per workspace directory and reread only when its mtime
 * moves. Grok writes `subagents/<child>` before it creates the child's session
 * directory, and creating that directory is what moves the mtime.
 */
export class GrokSubagentParents {
  constructor() {
    this.cache = new Map();
  }

  async annotate(items) {
    const pass = new Map();
    for (const item of items ?? []) {
      if (item?.provider !== "grok") continue;
      const session = item.link_session ?? item.session;
      const workspace = grokWorkspace(item, session);
      if (!workspace) continue;
      if (!pass.has(workspace)) pass.set(workspace, await this.#links(workspace));
      const parent = pass.get(workspace).get(session);
      if (!parent || parent === session) continue;
      item.parent = parent;
      item.parent_provider = "grok";
      item.parent_source = "grok-subagent";
      // The parent's `grok -p` argv is not the sub-agent's: it is a worker,
      // not a one-shot run.
      delete item.headless;
    }
    for (const workspace of [...this.cache.keys()]) if (!pass.has(workspace)) this.cache.delete(workspace);
  }

  async #links(workspace) {
    let mtime;
    try {
      mtime = (await stat(workspace)).mtimeMs;
    } catch {
      this.cache.delete(workspace);
      return new Map();
    }
    const cached = this.cache.get(workspace);
    if (cached?.mtime === mtime) return cached.links;
    const links = await grokSubagentLinks(workspace);
    this.cache.set(workspace, { mtime, links });
    return links;
  }
}

/** The encoded-cwd directory holding a Grok session, from its transcript or cwd. */
function grokWorkspace(item, session) {
  if (typeof session !== "string" || !LINEAGE_ID.test(session)) return null;
  if (typeof item.transcript === "string" && basename(item.transcript) === session) return dirname(item.transcript);
  return null;
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
      const lastTurn = await lastGrokTurn(eventPath);
      // An interactive grok between turns is a session waiting for its user,
      // not a vanished one: it stays listed as ready until the process exits.
      // A multiplexed `grok agent stdio` keeps every session it ever opened
      // held, so only its open turns mean anything.
      const interactive = !isMultiplexedGrokProcess(command, args);
      if (lastTurn !== "turn_started" && !(interactive && lastTurn === "turn_ended")) continue;
      const state = lastTurn === "turn_started" ? "running" : "ready";
      const sessionDirectory = dirname(eventPath);
      // The provider-side id is stable across pid reuse and matches the
      // Gateway's acpSessionId, allowing mergeMonitorSessions to dedupe a
      // Gateway-owned worker while still exposing an independent local CLI.
      const session = basename(sessionDirectory);
      const stateKey = `grok:${session}`;
      states[stateKey] = {
        provider: "grok",
        session,
        state,
        event: `process/${state}`,
        time: previous[stateKey]?.state === state ? previous[stateKey].time : now,
        pid,
        parent: externalParent(parents ?? new Map(), "grok", session),
        engine: "grok-cli",
        cwd: decodeURIComponent(basename(dirname(sessionDirectory))),
        link_session: session,
        transcript: sessionDirectory,
        ...(headlessArgs("grok", args) ? { headless: true } : {})
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
