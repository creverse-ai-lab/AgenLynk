// Live session facts reported by agent hooks, merged into the local scan.
//
// The scanner infers liveness from files and processes; a hook states it.
// A session a hook reported stays listed until its SessionEnd (or until it has
// been silent for `staleAfterMs`), and a hook status newer than the scanner's
// replaces it — that is what makes "tool running" and "waiting for
// permission" show up the moment they happen for all three CLIs.
//
// A session a hook has only seen start (no prompt, tool, subagent or
// permission prompt) is held back, transcript or not: it is not
// listed, and it is forgotten at its SessionEnd or after HELD_BACK_TTL_MS.
// Tools that run an agent CLI as a probe (a usage meter starting `claude`
// every few minutes) would otherwise add an empty Frontdoor per run. The
// first real activity lists it like any other session. A transcript on disk
// is no proof: a probe writes one and deletes it, and a real session with a
// transcript is listed by the scanner on its own.

import { readdirSync, readFileSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { isWithin } from "../app/fs-paths.js";
import { headlessEntrypoint, markerParent } from "../local-agents/lineage.js";
import { HookNormalizer, readHookPayload } from "../normalize/hook.js";

const DEFAULT_STALE_AFTER_MS = 10 * 60 * 1000;
const HELD_BACK_TTL_MS = 2 * 60 * 1000;
const MAX_SESSIONS = 500;
const MAX_LINEAGE_ATTEMPTS = 3;

// Hook events that prove someone is using the session.
const ACTIVITY_EVENTS = new Set([
  "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest",
  "PermissionDenied", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"
]);

function isActivity(hook) {
  if (ACTIVITY_EVENTS.has(hook.event)) return true;
  return hook.event === "Notification" && hook.notificationType === "permission_prompt";
}

/** Listed at all: a hook saw real activity. */
function listable(entry) {
  return entry.active;
}

// Hook status -> the scanner's state vocabulary (see local-monitor.js).
const SCANNER_STATE = {
  running: "running",
  waiting_permission: "needs_permission",
  waiting_input: "needs_input",
  idle: "ready"
};

const BACKGROUND_RUNNING_TTL_MS = 120_000;

export class HookSessions {
  constructor({
    staleAfterMs = DEFAULT_STALE_AFTER_MS,
    grokRoot = join(homedir(), ".grok", "sessions"),
    claudeRoot = join(homedir(), ".claude", "projects"),
    claudeSessionsDir = join(homedir(), ".claude", "sessions"),
    isAlive = processAlive
  } = {}) {
    this.staleAfterMs = staleAfterMs;
    this.grokRoot = grokRoot;
    this.claudeRoot = claudeRoot;
    this.claudeSessionsDir = claudeSessionsDir;
    this.isAlive = isAlive;
    this.sessions = new Map();
    this.parents = new Map();
    // provider -> ms of the last hook received, so settings can tell
    // "registered" from "actually arriving".
    this.lastReceived = new Map();
  }

  lastReceivedAt() {
    return Object.fromEntries([...this.lastReceived].map(([provider, at]) => [provider, new Date(at).toISOString()]));
  }

  /**
   * Records one hook payload. Returns null for a payload without a session,
   * else the monitor session id and the events it produced. `lineage` holds
   * the launcher markers and parent pid the hook script forwarded
   * (hookLineageHeaders); `heldBack` says the session is not listed yet.
   */
  record(provider, payload, receivedAt = Date.now(), lineage = null) {
    // Grok runs the hooks in ~/.claude/settings.json too, with its own
    // camelCase payload. The script drops those by environment; this catches
    // the ones that arrive anyway, since Grok also reports them itself.
    if (provider === "claude" && payload && typeof payload === "object"
      && payload.session_id == null && (payload.sessionId != null || payload.hookEventName != null)) {
      return null;
    }
    this.lastReceived.set(provider, receivedAt);
    const sessionId = readHookPayload(provider, payload).sessionId;
    if (typeof sessionId !== "string" || !sessionId) return null;
    const key = `${provider}:${sessionId}`;
    let entry = this.sessions.get(key);
    if (!entry) {
      entry = {
        provider, session: sessionId, normalizer: new HookNormalizer(), status: null, statusAt: 0,
        firstSeen: receivedAt, active: false, markers: {}, ppid: null, parent: null
      };
      this.sessions.set(key, entry);
      if (this.sessions.size > MAX_SESSIONS) this.sessions.delete(this.sessions.keys().next().value);
    }
    const { hook, statusAt, events, status: reported } = entry.normalizer.ingest(provider, payload, receivedAt);
    let status = reported;
    entry.lastSeen = receivedAt;
    if (isActivity(hook)) entry.active = true;
    if (lineage?.markers) entry.markers = { ...entry.markers, ...lineage.markers };
    if (lineage?.ppid && !entry.ppid) entry.ppid = lineage.ppid;
    if (provider === "claude" && headlessEntrypoint(entry.markers.entrypoint)) entry.headless = true;
    // The folder it was started in names the session; later payloads carry
    // wherever its shell has since cd'ed to.
    if (hook.cwd && !entry.cwd) {
      entry.cwd = hook.cwd;
      // Only a session seen from its start knows its launch folder this way.
      entry.cwdIsLaunch = hook.event === "SessionStart";
    }
    if (hook.model) entry.model = hook.model;
    // A transcript path from a payload is only followed inside the agent's
    // own transcript tree: the monitor must never become a reader of
    // arbitrary files because a hook named one.
    if (provider === "claude" && isWithin(this.claudeRoot, hook.transcriptPath) && hook.transcriptPath.endsWith(".jsonl")) {
      entry.transcript = hook.transcriptPath;
    } else if (provider === "grok" && entry.cwd && /^[A-Za-z0-9-]+$/.test(entry.session)) {
      entry.transcript = join(this.grokRoot, encodeURIComponent(entry.cwd), entry.session);
    }
    // A Claude turn that ends with background tasks still out is not at
    // rest: it wakes itself when they report back.
    const backgroundTasks = Array.isArray(payload?.background_tasks) ? payload.background_tasks.length : 0;
    if (status === "idle" && hook.event === "Stop" && backgroundTasks > 0) status = "running";
    entry.backgroundTasks = hook.event === "Stop" ? backgroundTasks : (entry.backgroundTasks ?? 0);
    // Only that Stop's "running" is provisional (see merge); any later hook
    // speaks for itself.
    entry.backgroundRunning = hook.event === "Stop" && backgroundTasks > 0;
    if (status) {
      entry.status = status;
      entry.statusAt = Date.parse(statusAt) || receivedAt;
      entry.event = hook.event;
    }
    return {
      key,
      sessionId: `local:${provider}:${entry.session}`,
      localSessionId: entry.session,
      events,
      status,
      heldBack: !listable(entry)
    };
  }

  /**
   * A notch reply turned this session's Stop into another round: it is
   * working again, though no hook says so until its next tool call.
   */
  markRunning(key, at = Date.now()) {
    const entry = this.sessions.get(key);
    if (!entry) return;
    entry.status = "running";
    entry.statusAt = at;
    entry.event = "NotchReply";
  }

  /**
   * Whether a person is on the other end of this session's Stop: a root
   * session (no launching agent) whose own process was found and is not a
   * one-shot run. Only such a Frontdoor gets a notch reply window.
   */
  replyTarget(key) {
    const entry = this.sessions.get(key);
    if (!entry) return null;
    const person = !entry.headless || entry.interactiveKind;
    const eligible = Boolean(entry.lineageResolved && entry.agentPid && person && !entry.parent && !entry.gatewayWorker);
    return { eligible, provider: entry.provider, cwd: entry.cwd ?? null, backgroundTasks: entry.backgroundTasks ?? 0 };
  }

  /**
   * Resolves once per session which agent session launched it: from the
   * hook's parent pid up to the agent process (then that process's own
   * lineage, see ProcessLineage), else from the markers the hook forwarded.
   */
  async resolveLineage(key, lineage, nowMs = Date.now()) {
    const entry = this.sessions.get(key);
    if (!entry || entry.lineageResolved) return;
    // Retried on the next hooks until the process tree answers: a first
    // attempt can miss a process the table has not caught up with.
    entry.lineageAttempts = (entry.lineageAttempts ?? 0) + 1;
    if (entry.lineageAttempts >= MAX_LINEAGE_ATTEMPTS) entry.lineageResolved = true;
    const self = { provider: entry.provider, session: entry.session };
    let agentPid = null;
    if (lineage && entry.ppid) {
      try {
        await lineage.refresh(nowMs / 1000);
        // A process younger than the table's TTL is not in it yet.
        if (!lineage.table.has(entry.ppid)) await lineage.refresh(nowMs / 1000, { force: true });
        agentPid = lineage.agentPidFromHook(entry.ppid, entry.provider);
        if (agentPid) {
          entry.agentPid = agentPid;
          if (entry.provider === "claude") await this.#readClaudeSession(entry, agentPid);
          const resolved = await lineage.resolve(agentPid, self);
          if (resolved.parent) entry.parent = resolved.parent;
          if (resolved.headless) entry.headless = true;
          if (resolved.interactive) entry.interactive = true;
          if (resolved.gatewayWorker) entry.gatewayWorker = true;
          entry.lineageResolved = true;
        }
      } catch {
        agentPid = null;
      }
    }
    // The process tree is the better witness; the forwarded markers only
    // stand in when the agent's process could not be found.
    if (!agentPid && !entry.parent) entry.parent = markerParent(entry.markers, self);
    if (entry.parent) this.#rememberParent(key, entry.parent);
  }

  // A launcher learned from hooks outlives the hook session: a short
  // `grok -p` often ends (SessionEnd drops the entry) before the scanner
  // has seen its process, and the scanner's record must still get it.
  #rememberParent(key, parent) {
    this.parents.delete(key);
    this.parents.set(key, parent);
    while (this.parents.size > MAX_SESSIONS) this.parents.delete(this.parents.keys().next().value);
  }

  /** Live Claude sessions (id -> the folder each was started in), or null where Claude keeps no such records. */
  #liveClaudeSessions(nowMs) {
    if (this.liveCache && nowMs - this.liveCache.at < 1_000) return this.liveCache.ids;
    let ids = null;
    try {
      const names = readdirSync(this.claudeSessionsDir).filter((name) => /^\d+\.json$/.test(name));
      if (names.length) {
        ids = new Map();
        for (const name of names) {
          try {
            // A crash or SIGKILL leaves the file behind; only a live pid counts.
            if (!this.isAlive(Number(name.slice(0, -".json".length)))) continue;
            const record = JSON.parse(readFileSync(join(this.claudeSessionsDir, name), "utf8"));
            if (typeof record?.sessionId === "string") ids.set(record.sessionId, typeof record.cwd === "string" ? record.cwd : null);
          } catch {
            // Half-written or foreign file.
          }
        }
      }
    } catch {
      ids = null;
    }
    this.liveCache = { at: nowMs, ids };
    return ids;
  }

  // Claude's own record of a live session (~/.claude/sessions/<pid>.json):
  // the folder it was started in, and whether a person drives it. An IDE or
  // desktop host runs Claude as `sdk-cli` yet marks it "interactive".
  async #readClaudeSession(entry, pid) {
    try {
      const record = JSON.parse(await readFile(join(this.claudeSessionsDir, `${pid}.json`), "utf8"));
      if (record?.sessionId !== entry.session) return;
      if (typeof record.cwd === "string" && record.cwd) {
        entry.cwd = record.cwd;
        entry.cwdIsLaunch = true;
      }
      if (record.kind === "interactive") entry.interactiveKind = true;
    } catch {
      // No record (an older Claude, or already gone): nothing to add.
    }
  }

  /** The hook-learned launcher of a session, if any. */
  parentOf(provider, session) {
    return this.parents.get(`${provider}:${session}`) ?? null;
  }

  /**
   * Overlays hook facts onto the scanner's raw sessions and adds the live
   * sessions the scanner did not report. Ended and stale sessions drop out.
   */
  merge(rawSessions, nowMs = Date.now()) {
    const merged = (Array.isArray(rawSessions) ? rawSessions : []).map((raw) => ({ ...raw }));
    const byKey = new Map(merged.map((raw) => [`${raw.provider}:${raw.session}`, raw]));
    for (const [key, entry] of this.sessions) {
      if (nowMs - entry.lastSeen > this.staleAfterMs) {
        this.sessions.delete(key);
        continue;
      }
      const raw = byKey.get(key);
      // Killed without a SessionEnd (a closed terminal, SIGTERM): its
      // process is the witness that it is over.
      // Its record is dropped with it, so a `--resume` of the same session in
      // a new process starts over (new lineage, new pid) instead of being
      // judged by the dead one.
      if (entry.agentPid && !this.isAlive(entry.agentPid)) {
        if (raw) merged.splice(merged.indexOf(raw), 1);
        this.sessions.delete(key);
        continue;
      }
      if (entry.status === "closed") {
        if (raw) merged.splice(merged.indexOf(raw), 1);
        // Nothing ever listed it: its end is the end of it.
        else if (!listable(entry)) this.sessions.delete(key);
        continue;
      }
      // A turn left background work running: running while that work is
      // likely still reporting back, at rest after that (a dev server or a
      // `tail -f` never wakes it, and the person is the one waiting).
      if (entry.backgroundRunning && entry.status === "running" && nowMs - entry.statusAt > BACKGROUND_RUNNING_TTL_MS) {
        entry.status = "idle";
        entry.backgroundRunning = false;
      }
      const state = SCANNER_STATE[entry.status];
      if (raw) {
        raw.hooked = true;
        // A scanner-proven parent (Gateway/MCP link, discovery lineage) wins.
        if (!raw.parent && entry.parent) {
          raw.parent = entry.parent.session;
          raw.parent_provider = entry.parent.provider;
          raw.parent_source = "lineage";
        }
        if (entry.headless) raw.headless = true;
        if (entry.interactive) raw.interactive = true;
        if (state && entry.statusAt / 1000 >= Number(raw.time || 0)) {
          raw.state = state;
          raw.event = `hook/${entry.event}`;
          raw.time = entry.statusAt / 1000;
        }
        if (!raw.transcript && entry.transcript) raw.transcript = entry.transcript;
        // The hook knows where it was started; the transcript only where
        // its last record ran.
        if (entry.cwd && (entry.cwdIsLaunch || !raw.cwd)) raw.cwd = entry.cwd;
        continue;
      }
      if (!state) continue;
      if (!listable(entry)) {
        if (nowMs - entry.firstSeen > HELD_BACK_TTL_MS) this.sessions.delete(key);
        continue;
      }
      merged.push({
        provider: entry.provider,
        session: entry.session,
        state,
        event: `hook/${entry.event}`,
        time: entry.statusAt / 1000,
        pid: null,
        parent: null,
        engine: entry.model ?? null,
        cwd: entry.cwd ?? null,
        transcript: entry.transcript ?? null,
        hooked: true,
        ...(entry.parent ? { parent: entry.parent.session, parent_provider: entry.parent.provider, parent_source: "lineage" } : {}),
        ...(entry.headless ? { headless: true } : {}),
        ...(entry.interactive ? { interactive: true } : {})
      });
    }
    for (const raw of merged) {
      if (raw.parent) continue;
      const parent = this.parentOf(raw.provider, raw.session);
      if (!parent) continue;
      raw.parent = parent.session;
      raw.parent_provider = parent.provider;
      raw.parent_source = "lineage";
    }
    // A finished Claude Frontdoor has no record in ~/.claude/sessions (Claude
    // keeps one per live process). Without this, one that ended without a
    // SessionEnd sits "idle" for the whole retention window.
    const live = this.#liveClaudeSessions(nowMs);
    if (live) {
      for (let index = merged.length - 1; index >= 0; index -= 1) {
        const raw = merged[index];
        if (raw.provider !== "claude") continue;
        if (!raw.parent && raw.state === "ready" && !live.has(raw.session)) {
          merged.splice(index, 1);
          continue;
        }
        // Where it was started, also before any hook (e.g. right after a
        // monitor restart) has said so.
        if (!raw.hooked && live.get(raw.session)) raw.cwd = live.get(raw.session);
      }
    }
    return merged;
  }
}

function processAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    // EPERM: alive, just not ours to signal.
    return error?.code === "EPERM";
  }
}
