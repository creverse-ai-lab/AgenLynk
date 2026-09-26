// Live session facts reported by agent hooks, merged into the local scan.
//
// The scanner infers liveness from files and processes; a hook states it.
// A session a hook reported stays listed until its SessionEnd (or until it has
// been silent for `staleAfterMs`), and a hook status newer than the scanner's
// replaces it — that is what makes "tool running" and "waiting for
// permission" show up the moment they happen for all three CLIs.

import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { HookNormalizer, readHookPayload } from "../normalize/hook.js";

const DEFAULT_STALE_AFTER_MS = 10 * 60 * 1000;
const MAX_SESSIONS = 500;

// Hook status -> the scanner's state vocabulary (see local-monitor.js).
const SCANNER_STATE = {
  running: "running",
  waiting_permission: "needs_permission",
  waiting_input: "needs_input",
  idle: "ready"
};

export class HookSessions {
  constructor({
    staleAfterMs = DEFAULT_STALE_AFTER_MS,
    grokRoot = join(homedir(), ".grok", "sessions"),
    claudeRoot = join(homedir(), ".claude", "projects")
  } = {}) {
    this.staleAfterMs = staleAfterMs;
    this.grokRoot = grokRoot;
    this.claudeRoot = claudeRoot;
    this.sessions = new Map();
    // provider -> ms of the last hook received, so settings can tell
    // "registered" from "actually arriving".
    this.lastReceived = new Map();
  }

  lastReceivedAt() {
    return Object.fromEntries([...this.lastReceived].map(([provider, at]) => [provider, new Date(at).toISOString()]));
  }

  /**
   * Records one hook payload. Returns null for a payload without a session,
   * else the monitor session id and the events it produced.
   */
  record(provider, payload, receivedAt = Date.now()) {
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
      entry = { provider, session: sessionId, normalizer: new HookNormalizer(), status: null, statusAt: 0 };
      this.sessions.set(key, entry);
      if (this.sessions.size > MAX_SESSIONS) this.sessions.delete(this.sessions.keys().next().value);
    }
    const { hook, status, statusAt, events } = entry.normalizer.ingest(provider, payload, receivedAt);
    entry.lastSeen = receivedAt;
    if (hook.cwd) entry.cwd = hook.cwd;
    if (hook.model) entry.model = hook.model;
    // A transcript path from a payload is only followed inside the agent's
    // own transcript tree: the monitor must never become a reader of
    // arbitrary files because a hook named one.
    if (provider === "claude" && isWithin(this.claudeRoot, hook.transcriptPath) && hook.transcriptPath.endsWith(".jsonl")) {
      entry.transcript = hook.transcriptPath;
    } else if (provider === "grok" && entry.cwd && /^[A-Za-z0-9-]+$/.test(entry.session)) {
      entry.transcript = join(this.grokRoot, encodeURIComponent(entry.cwd), entry.session);
    }
    if (status) {
      entry.status = status;
      entry.statusAt = Date.parse(statusAt) || receivedAt;
      entry.event = hook.event;
    }
    return { sessionId: `local:${provider}:${entry.session}`, events, status };
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
      if (entry.status === "closed") {
        if (raw) merged.splice(merged.indexOf(raw), 1);
        continue;
      }
      const state = SCANNER_STATE[entry.status];
      if (raw) {
        raw.hooked = true;
        if (state && entry.statusAt / 1000 >= Number(raw.time || 0)) {
          raw.state = state;
          raw.event = `hook/${entry.event}`;
          raw.time = entry.statusAt / 1000;
        }
        if (!raw.transcript && entry.transcript) raw.transcript = entry.transcript;
        if (!raw.cwd && entry.cwd) raw.cwd = entry.cwd;
        continue;
      }
      if (!state) continue;
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
        hooked: true
      });
    }
    return merged;
  }
}

function isWithin(root, path) {
  if (typeof root !== "string" || typeof path !== "string" || !isAbsolute(path)) return false;
  const child = relative(resolve(root), resolve(path));
  return child !== "" && child !== ".." && !child.startsWith(`..${sep}`) && !isAbsolute(child);
}
