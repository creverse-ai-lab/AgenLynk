// Which local agent session launched this one, from the process tree.
//
// An agent started from another agent's shell tool (`grok -p ...` run by a
// Claude Code Bash call, `codex exec` from Grok, a nested `claude -p`) is that
// session's worker, not a Frontdoor of its own. Two facts prove it:
//   - the launcher's session id, which every CLI exports to the commands it
//     runs (CLAUDE_CODE_SESSION_ID, GROK_SESSION_ID, CODEX_THREAD_ID) and the
//     child inherits in its initial environment, and
//   - the parent-pid chain up to the launcher's own process (Claude records
//     pid -> session in ~/.claude/sessions/<pid>.json).
//
// Privacy: only those three ids are ever parsed out of a process
// environment, each validated to a strict id charset. The
// rest of the environment is read by `ps` and discarded unparsed; nothing of
// it is stored or logged.

import { execFile } from "node:child_process";
import { readdir, readFile, realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const PROCESS_TIMEOUT_MS = 1_000;
const MAX_HOPS = 64;
/** Process table and Claude pid files are re-read at most this often. */
const TABLE_TTL_SECONDS = 5;
const MAX_CACHED = 2_000;
/**
 * A `codex exec` process starts its thread within this many seconds of its
 * own start (both are whole seconds).
 */
export const EXEC_MATCH_WINDOW_SECONDS = 15;

/** The only shape an id taken from an environment or a header may have. */
export const LINEAGE_ID = /^[A-Za-z0-9_-]{1,128}$/;

const MARKER_KEYS = {
  CLAUDE_CODE_SESSION_ID: "claude",
  GROK_SESSION_ID: "grok",
  CODEX_THREAD_ID: "codex"
};

async function runCommand(command, args) {
  try {
    const { stdout } = await execFileAsync(command, args, {
      timeout: PROCESS_TIMEOUT_MS,
      maxBuffer: 4 * 1024 * 1024,
      // lstart in UTC and C locale, so it compares with Claude's procStart.
      env: { ...process.env, TZ: "UTC", LC_ALL: "C" }
    });
    return stdout;
  } catch (error) {
    return typeof error?.stdout === "string" ? error.stdout : "";
  }
}

/**
 * Lineage markers from `ps eww -o command=` (args followed by the initial
 * environment) given the same process's `ps ww -o command=` (args only).
 * Only the part after the args is read, so a prompt that merely mentions a
 * marker cannot pose as one. A key seen twice with different values is
 * ambiguous and dropped.
 */
export function lineageMarkers(withEnvironment, argsOnly) {
  const markers = {};
  if (typeof withEnvironment !== "string" || typeof argsOnly !== "string") return markers;
  const full = withEnvironment.replace(/\n+$/, "");
  const args = argsOnly.replace(/\n+$/, "");
  if (!args || !full.startsWith(args)) return markers;
  const conflicted = new Set();
  for (const token of full.slice(args.length).split(/\s+/)) {
    const separator = token.indexOf("=");
    if (separator <= 0) continue;
    const name = MARKER_KEYS[token.slice(0, separator)];
    if (!name) continue;
    const value = token.slice(separator + 1);
    if (!LINEAGE_ID.test(value)) continue;
    if (markers[name] != null && markers[name] !== value) conflicted.add(name);
    markers[name] = value;
  }
  for (const name of conflicted) delete markers[name];
  return markers;
}

/** Markers forwarded by agenlynk-hook.sh, validated the same way. */
export function hookLineageHeaders(headers = {}) {
  const pick = (name) => {
    const value = headers[name];
    return typeof value === "string" && LINEAGE_ID.test(value) ? value : null;
  };
  const markers = {};
  for (const [header, name] of [
    ["x-agenlynk-parent-claude", "claude"],
    ["x-agenlynk-parent-grok", "grok"],
    ["x-agenlynk-parent-codex", "codex"],
    ["x-agenlynk-entrypoint", "entrypoint"]
  ]) {
    const value = pick(header);
    if (value) markers[name] = value;
  }
  const ppid = Number.parseInt(pick("x-agenlynk-hook-ppid") ?? "", 10);
  return { markers, ppid: Number.isInteger(ppid) && ppid > 1 ? ppid : null };
}

/** Which agent CLI a process executable is, or null. */
export function agentKind(comm) {
  const name = basename(String(comm ?? "").trim());
  if (name === "claude") return "claude";
  if (/^grok(?:-\d[\w.]*)?$/.test(name)) return "grok";
  if (name === "codex") return "codex";
  return null;
}

/** The Gateway daemon owns the parent links of everything it spawns. */
function isGatewayProcess(comm) {
  return String(comm ?? "").includes("/.acp-gateway/runtime/");
}

/** `ps -axo pid=,ppid=,lstart=,comm=` -> Map(pid -> { ppid, start, comm }). */
export function parseProcessTable(stdout) {
  const table = new Map();
  for (const line of String(stdout ?? "").split("\n")) {
    const match = /^\s*(\d+)\s+(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+[\d:]+\s+\d{4})\s+(.+)$/.exec(line);
    if (!match) continue;
    table.set(Number(match[1]), { ppid: Number(match[2]), start: match[3].replace(/\s+/g, " "), comm: match[4].trim() });
  }
  return table;
}

/** `lsof -a -d cwd -p <pids> -Fn` -> Map(pid -> cwd). */
export function parseLsofCwds(stdout) {
  const cwds = new Map();
  let pid = null;
  for (const line of String(stdout ?? "").split("\n")) {
    if (line.startsWith("p")) {
      const parsed = Number.parseInt(line.slice(1), 10);
      pid = Number.isInteger(parsed) ? parsed : null;
    } else if (pid != null && line.startsWith("n") && line.length > 1 && !cwds.has(pid)) {
      cwds.set(pid, line.slice(1));
    }
  }
  return cwds;
}

/** Epoch seconds of a process table `start` (UTC lstart), or NaN. */
function startSeconds(start) {
  return Date.parse(`${start} GMT`) / 1000;
}

/**
 * The one non-launcher candidate among `markers`, excluding the session's own
 * id; null when there is none or more than one (then only the process tree
 * can say which is nearest).
 */
export function markerParent(markers, self) {
  const candidates = ["claude", "grok", "codex"]
    .filter((provider) => markers?.[provider] && !(provider === self?.provider && markers[provider] === self?.session))
    .map((provider) => ({ provider, session: markers[provider] }));
  return candidates.length === 1 ? candidates[0] : null;
}

/** True when a Claude entrypoint names a headless (SDK / `claude -p`) run. */
export function headlessEntrypoint(entrypoint) {
  return typeof entrypoint === "string" && /^sdk/.test(entrypoint);
}

const HEADLESS_FLAGS = {
  claude: /(?:^|\s)(?:-p|--print)(?:[\s=]|$)/,
  grok: /(?:^|\s)(?:-p|--single|--prompt-file|--prompt-json)(?:[\s=]|$)/,
  codex: /(?:^|\s)exec(?:\s|$)/
};

/** True when an agent's command line is a one-shot, non-interactive run. */
export function headlessArgs(provider, args) {
  if (typeof args !== "string") return false;
  // Flags after the executable only; the executable path itself is not one.
  const rest = args.trim().replace(/^\S+/, "");
  return HEADLESS_FLAGS[provider]?.test(rest) ?? false;
}

export class ProcessLineage {
  constructor({
    claudeSessionsDir = join(homedir(), ".claude", "sessions"),
    run = runCommand
  } = {}) {
    this.claudeSessionsDir = claudeSessionsDir;
    this.run = run;
    this.table = new Map();
    this.claudePids = new Map();
    this.loadedAt = -Infinity;
    // `${pid}@${start}` -> resolved lineage, so pid reuse is a new entry.
    this.cache = new Map();
    // `${pid}@${start}` -> working directory of a codex process (or null).
    this.cwds = new Map();
  }

  /** Refreshes the process table and Claude's pid files, at most every TTL. */
  async refresh(now = Date.now() / 1000, { force = false } = {}) {
    if (!force && now - this.loadedAt < TABLE_TTL_SECONDS) return;
    this.loadedAt = now;
    this.table = parseProcessTable(await this.run("ps", ["-axo", "pid=,ppid=,lstart=,comm="]));
    this.claudePids = await this.#readClaudePids();
    for (const key of [...this.cache.keys()]) {
      const [pid, start] = key.split("@");
      if (this.table.get(Number(pid))?.start !== start) this.cache.delete(key);
    }
    for (const key of [...this.cwds.keys()]) {
      const [pid, start] = key.split("@");
      if (this.table.get(Number(pid))?.start !== start) this.cwds.delete(key);
    }
  }

  /**
   * The running codex process that started a thread: the same working
   * directory and a start within EXEC_MATCH_WINDOW_SECONDS of the thread's
   * created_at. `codex exec` does not keep its rollout open, so this is the
   * only way from the thread to its pid. Only a unique match counts.
   * `final` says asking again cannot change the answer (ambiguous, or the
   * process table was read after the window closed without a candidate).
   * @returns {Promise<{ pid: number|null, final: boolean }>}
   */
  async codexExecPid({ cwd, createdAt }) {
    if (typeof cwd !== "string" || !cwd || !Number.isFinite(createdAt)) return { pid: null, final: true };
    // No process table (ps failed) says nothing yet.
    if (!this.table.size) return { pid: null, final: false };
    const candidates = [];
    for (const [pid, entry] of this.table) {
      if (agentKind(entry.comm) !== "codex") continue;
      if (Math.abs(startSeconds(entry.start) - createdAt) <= EXEC_MATCH_WINDOW_SECONDS) candidates.push(pid);
    }
    const closed = this.loadedAt > createdAt + EXEC_MATCH_WINDOW_SECONDS;
    if (!candidates.length) return { pid: null, final: closed };
    const key = (pid) => `${pid}@${this.table.get(pid).start}`;
    const unknown = candidates.filter((pid) => !this.cwds.has(key(pid)));
    if (unknown.length) {
      const found = parseLsofCwds(await this.run("lsof", ["-a", "-d", "cwd", "-p", unknown.join(","), "-Fn"]));
      for (const pid of unknown) this.cwds.set(key(pid), found.get(pid) ?? null);
      while (this.cwds.size > MAX_CACHED) this.cwds.delete(this.cwds.keys().next().value);
    }
    const targets = new Set([cwd]);
    try {
      targets.add(await realpath(cwd));
    } catch {
      // A removed directory still matches by its recorded path.
    }
    const matches = candidates.filter((pid) => targets.has(this.cwds.get(key(pid))));
    if (matches.length === 1) return { pid: matches[0], final: true };
    return { pid: null, final: matches.length > 1 || closed };
  }

  /** Claude session id -> live pid, from ~/.claude/sessions. */
  claudePidForSession(sessionId) {
    for (const [pid, record] of this.claudePids) {
      if (record.sessionId === sessionId && this.#claudeRecordLive(pid, record)) return pid;
    }
    return null;
  }

  claudeRecord(pid) {
    const record = this.claudePids.get(pid);
    return record && this.#claudeRecordLive(pid, record) ? record : null;
  }

  /**
   * From a hook script's parent pid, the agent process running the hook: the
   * nearest ancestor of the hook's own provider (the hook runs under a shell
   * the CLI started).
   */
  agentPidFromHook(ppid, provider) {
    let current = ppid;
    for (let hop = 0; hop < 8 && current > 1; hop += 1) {
      const entry = this.table.get(current);
      if (!entry) return null;
      if (agentKind(entry.comm) === provider) return current;
      current = entry.ppid;
    }
    return null;
  }

  /**
   * The session that launched agent process `pid`, or null.
   * @returns {Promise<{ parent: { provider, session }|null, headless: boolean }>}
   */
  async resolve(pid, self) {
    const entry = this.table.get(pid);
    if (!Number.isInteger(pid) || !entry) return { parent: null, headless: false };
    const key = `${pid}@${entry.start}`;
    const cached = this.cache.get(key);
    if (cached && cached.self === `${self?.provider}:${self?.session}`) return cached.value;
    const { markers, args } = await this.#markers(pid);
    const value = { parent: this.#walk(entry.ppid, markers, self), headless: headlessArgs(self?.provider, args) };
    this.cache.set(key, { self: `${self?.provider}:${self?.session}`, value });
    if (this.cache.size > MAX_CACHED) this.cache.delete(this.cache.keys().next().value);
    return value;
  }

  #walk(start, markers, self) {
    const isSelf = (candidate) => candidate.provider === self?.provider && candidate.session === self?.session;
    let current = start;
    for (let hop = 0; hop < MAX_HOPS && current > 1; hop += 1) {
      const entry = this.table.get(current);
      if (!entry) break;
      if (isGatewayProcess(entry.comm)) return null;
      const kind = agentKind(entry.comm);
      let candidate = null;
      if (kind === "claude") {
        // The id at spawn time (the env marker) names the session that ran
        // the command; the pid file names whatever that process holds now.
        const session = markers.claude ?? this.claudeRecord(current)?.sessionId ?? null;
        candidate = session ? { provider: "claude", session } : null;
      } else if (kind === "grok" || kind === "codex") {
        candidate = markers[kind] ? { provider: kind, session: markers[kind] } : null;
      }
      if (kind) return candidate && !isSelf(candidate) ? candidate : null;
      current = entry.ppid;
    }
    // The launcher already exited (the chain ends at launchd): its exported
    // id is still proof, as long as it is unambiguous.
    return markerParent(markers, self);
  }

  async #markers(pid) {
    const [withEnvironment, argsOnly] = await Promise.all([
      this.run("ps", ["eww", "-o", "command=", "-p", String(pid)]),
      this.run("ps", ["ww", "-o", "command=", "-p", String(pid)])
    ]);
    // Only the flags are kept (for headlessArgs); the command line is not stored.
    return { markers: lineageMarkers(withEnvironment, argsOnly), args: argsOnly.split("\n", 1)[0] };
  }

  #claudeRecordLive(pid, record) {
    const entry = this.table.get(pid);
    if (!entry || agentKind(entry.comm) !== "claude") return false;
    if (record.procStart && record.procStart.replace(/\s+/g, " ") === entry.start) return true;
    // Without a matching procStart, the recorded start must be within a
    // minute of the process's own: a reused pid is not that session.
    const started = Date.parse(`${entry.start} GMT`);
    return Number.isFinite(started) && Number.isFinite(record.startedAt) && Math.abs(record.startedAt - started) < 60_000;
  }

  async #readClaudePids() {
    const pids = new Map();
    let names;
    try {
      names = await readdir(this.claudeSessionsDir);
    } catch {
      return pids;
    }
    for (const name of names) {
      const match = /^(\d+)\.json$/.exec(name);
      if (!match) continue;
      try {
        const record = JSON.parse(await readFile(join(this.claudeSessionsDir, name), "utf8"));
        if (typeof record?.sessionId !== "string" || !LINEAGE_ID.test(record.sessionId)) continue;
        pids.set(Number(match[1]), {
          sessionId: record.sessionId,
          procStart: typeof record.procStart === "string" ? record.procStart : null,
          startedAt: Number(record.startedAt),
          entrypoint: typeof record.entrypoint === "string" ? record.entrypoint : null,
          kind: typeof record.kind === "string" ? record.kind : null
        });
      } catch {
        // Half-written or foreign file.
      }
    }
    return pids;
  }
}

/**
 * Fills `parent` from process lineage on scanner items that have none. A
 * proven (Gateway/MCP) link already set on an item always wins.
 */
export async function annotateLineage(items, lineage, now = Date.now() / 1000) {
  if (!lineage) return;
  await lineage.refresh(now);
  for (const item of items) {
    if (!item || (item.provider !== "claude" && item.provider !== "grok")) continue;
    if (item.agent_id) continue;
    const session = item.link_session ?? item.session;
    let pid = Number.isInteger(item.pid) ? item.pid : null;
    if (item.provider === "claude") {
      pid ??= lineage.claudePidForSession(session);
      const record = pid ? lineage.claudeRecord(pid) : null;
      if (headlessEntrypoint(record?.entrypoint)) item.headless = true;
    }
    if (item.parent || !pid) continue;
    const { parent, headless } = await lineage.resolve(pid, { provider: item.provider, session });
    if (headless) item.headless = true;
    if (!parent) continue;
    item.parent = parent.session;
    item.parent_provider = parent.provider;
    item.parent_source = "lineage";
  }
}

/**
 * Parents from process lineage for Codex threads started by `codex exec`
 * (thread source "exec") that carry no proven link. The result is kept on the
 * transcript cursor (`cursor.exec.parent`), so it outlives the process; each
 * cursor is resolved at most once.
 */
export async function annotateExecLineage(cursors, lineage, now = Date.now() / 1000) {
  if (!lineage) return;
  const pending = [...cursors.values()].filter((cursor) => cursor?.exec && !cursor.exec.done);
  if (!pending.length) return;
  await lineage.refresh(now);
  for (const cursor of pending) {
    const match = await lineage.codexExecPid(cursor.exec);
    if (match.pid == null) {
      if (match.final) cursor.exec.done = true;
      continue;
    }
    cursor.exec.done = true;
    const { parent, headless } = await lineage.resolve(match.pid, { provider: "codex", session: cursor.session });
    // The matched process must really be a one-shot `codex exec` run.
    if (headless && parent) cursor.exec.parent = parent;
  }
}
