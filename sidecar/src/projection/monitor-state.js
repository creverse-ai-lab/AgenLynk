// Wire contract for the native Monitor app's HTTP/SSE API, independent of
// GATEWAY_API_VERSION (the Gateway daemon's own setup/subscribe handshake).
// Bump MONITOR_SCHEMA_VERSION only when a field is removed, renamed, or
// changes meaning; additive fields do not require a bump.
export const MONITOR_SCHEMA_VERSION = 1;
export const MONITOR_API_VERSION = "1.0";

export class MonitorState {
  constructor({ maxEventsPerSession = 2000, historyRetentionMs = 65 * 60 * 1000 } = {}) {
    this.maxEventsPerSession = maxEventsPerSession;
    this.historyRetentionMs = historyRetentionMs;
    this.sessions = new Map();
    // Raw Gateway session source retained inside the canonical state owner so
    // transport callbacks do not maintain a competing module-level copy.
    this.gatewaySourceSessions = [];
    this.eventsBySession = new Map();
    this.eventSequencesBySession = new Map();
    this.historySessions = new Map();
    this.historyEventsBySession = new Map();
    this.historyExpiresAt = new Map();
    this.externalEventSessionIds = new Set();
    this.externalEventSignatures = new Map();
    this.closedSessionIds = new Set();
    this.closedSessionOrder = [];
    this.tasks = [];
    this.inbox = [];
    this.gateway = null;
    this.connected = false;
    this.streaming = false;
    this.lastError = null;
    this.streamHealth = "disconnected";
    this.diagnostics = {
      subscriptionGaps: 0,
      replayedEvents: 0,
      reconciliationRuns: 0,
      overflowDroppedEvents: 0,
      replayTruncations: 0
    };
    this.sseClients = new Set();
    this.revision = 0;
  }

  setConnection({ connected = this.connected, streaming = this.streaming, error = this.lastError, health } = {}) {
    const nextHealth = health ?? (connected ? (streaming ? "healthy" : "degraded") : "disconnected");
    const changed = this.connected !== connected || this.streaming !== streaming
      || this.lastError !== error || this.streamHealth !== nextHealth;
    this.connected = connected;
    this.streaming = streaming;
    this.lastError = error;
    this.streamHealth = nextHealth;
    if (changed) this.revision += 1;
    return changed;
  }

  setRecords({ tasks = this.tasks, inbox = this.inbox } = {}) {
    const changed = JSON.stringify(this.tasks) !== JSON.stringify(tasks)
      || JSON.stringify(this.inbox) !== JSON.stringify(inbox);
    this.tasks = tasks;
    this.inbox = inbox;
    if (changed) this.revision += 1;
    return changed;
  }

  setSessions(list) {
    const nextSessions = new Map(list
      .filter((session) => !this.closedSessionIds.has(session.sessionId))
      .map((session) => [session.sessionId, session]));
    const removedSessionIds = [...new Set([...this.sessions.keys(), ...this.eventsBySession.keys()])]
      .filter((sessionId) => !nextSessions.has(sessionId));
    for (const sessionId of removedSessionIds) this.removeSession(sessionId);
    const changed = sessionMapSignature(this.sessions) !== sessionMapSignature(nextSessions);
    this.sessions = nextSessions;
    if (changed) this.revision += 1;
    return removedSessionIds;
  }

  setGatewaySourceSessions(list) {
    this.gatewaySourceSessions = Array.isArray(list) ? list : [];
  }

  removeSession(sessionId, { closed = false } = {}) {
    const existed = this.sessions.has(sessionId) || this.eventsBySession.has(sessionId);
    this.archiveSession(sessionId);
    this.sessions.delete(sessionId);
    this.eventsBySession.delete(sessionId);
    this.eventSequencesBySession.delete(sessionId);
    this.externalEventSignatures.delete(sessionId);
    if (closed && !this.closedSessionIds.has(sessionId)) {
      this.closedSessionIds.add(sessionId);
      this.closedSessionOrder.push(sessionId);
      if (this.closedSessionOrder.length > 2_000) {
        this.closedSessionIds.delete(this.closedSessionOrder.shift());
      }
    }
    if (existed) this.revision += 1;
  }

  setGateway(gateway) {
    const changed = JSON.stringify(this.gateway) !== JSON.stringify(gateway);
    this.gateway = gateway;
    if (changed) this.revision += 1;
    return changed;
  }

  pushEvent(event, { replay = false } = {}) {
    // Gap/truncation markers are subscription control records, never timeline content.
    if (!event?.sessionId || event.type === "subscription_gap" || event.type === "subscription_replay_truncated") {
      return false;
    }
    const events = this.eventsBySession.get(event.sessionId) ?? [];
    const sequences = this.eventSequencesBySession.get(event.sessionId) ?? new Set();
    if (Number.isFinite(event.sequence) && sequences.has(event.sequence)) return false;

    events.push(event);
    if (Number.isFinite(event.sequence)) sequences.add(event.sequence);
    if (events.length > 1 && eventOrder(events.at(-1), events.at(-2)) < 0) events.sort(eventOrder);
    if (events.length > this.maxEventsPerSession) {
      const removed = events.splice(0, events.length - this.maxEventsPerSession);
      for (const item of removed) {
        if (Number.isFinite(item.sequence)) sequences.delete(item.sequence);
      }
      this.diagnostics.overflowDroppedEvents += removed.length;
    }
    this.eventsBySession.set(event.sessionId, events);
    this.eventSequencesBySession.set(event.sessionId, sequences);
    if (event.type === "session_closed" && this.sessions.has(event.sessionId)) {
      this.sessions.set(event.sessionId, {
        ...this.sessions.get(event.sessionId),
        status: "closed",
        updatedAt: event.ts ?? this.sessions.get(event.sessionId).updatedAt
      });
    }
    if (replay) this.diagnostics.replayedEvents += 1;
    this.revision += 1;
    return true;
  }

  beginSubscriptionGap(event) {
    this.diagnostics.subscriptionGaps += 1;
    this.setConnection({ connected: true, streaming: false, error: "Gateway subscription gap; reconciling", health: "reconciling" });
    // setConnection may be unchanged during a burst of markers, but every gap
    // is diagnostics state and therefore still advances the conditional tag.
    this.revision += 1;
    return {
      sessionId: event?.sessionId,
      fromSequence: Number.isFinite(event?.fromSequence) ? event.fromSequence : 0
    };
  }

  noteReplayTruncation(event = {}) {
    this.diagnostics.replayTruncations += 1;
    const sessionIds = Array.isArray(event.sessionIds)
      ? event.sessionIds.filter((sessionId) => typeof sessionId === "string" && sessionId)
      : event.sessionId ? [event.sessionId] : [];
    const detail = sessionIds.length ? ` (${sessionIds.join(", ")})` : "";
    this.setConnection({
      connected: true,
      streaming: true,
      error: `Gateway subscription replay truncated${detail}`,
      health: "degraded"
    });
    return { sessionIds };
  }

  completeReconciliation({ truncated = false } = {}) {
    this.diagnostics.reconciliationRuns += 1;
    if (truncated) {
      if (this.streamHealth !== "degraded") {
        this.noteReplayTruncation();
      } else {
        this.setConnection({
          connected: true,
          streaming: true,
          error: this.lastError ?? "Gateway subscription replay truncated",
          health: "degraded"
        });
      }
    } else {
      this.setConnection({ connected: true, streaming: true, error: null, health: "healthy" });
    }
    this.revision += 1;
  }

  subscriptionCursors(floors = {}) {
    const sessionIds = new Set([...this.eventsBySession.keys(), ...Object.keys(floors)]);
    return Object.fromEntries([...sessionIds].map((sessionId) => {
      const sequences = (this.eventsBySession.get(sessionId) ?? [])
        .map((event) => event.sequence).filter(Number.isFinite);
      const next = sequences.length ? Math.max(...sequences) + 1 : 0;
      const floor = Number.isFinite(floors[sessionId]) ? floors[sessionId] : next;
      return [sessionId, Math.min(next, floor)];
    }));
  }

  snapshotTag(now = Date.now()) {
    this.pruneHistory(now);
    return `\"monitor-${this.revision}\"`;
  }

  // Returns the sessionIds whose bucket actually changed (an emptied/dropped
  // bucket included), so a caller can stream just those buckets instead of
  // re-sending every local transcript on each scan.
  setExternalEvents(groups = {}) {
    const nextIds = new Set(Object.keys(groups));
    const changedSessionIds = [];
    for (const sessionId of this.externalEventSessionIds) {
      if (nextIds.has(sessionId)) continue;
      this.eventsBySession.delete(sessionId);
      this.eventSequencesBySession.delete(sessionId);
      this.externalEventSignatures.delete(sessionId);
      changedSessionIds.push(sessionId);
    }
    for (const [sessionId, values] of Object.entries(groups)) {
      const events = (Array.isArray(values) ? values : []).slice(-this.maxEventsPerSession);
      const signature = externalEventsSignature(events);
      if (this.externalEventSignatures.get(sessionId) === signature) continue;
      if (this.eventsBySession.has(sessionId)) this.archiveSession(sessionId);
      this.eventsBySession.set(sessionId, events);
      this.eventSequencesBySession.set(sessionId, new Set(
        events.map((event) => event.sequence).filter(Number.isFinite)
      ));
      this.externalEventSignatures.set(sessionId, signature);
      changedSessionIds.push(sessionId);
    }
    this.externalEventSessionIds = nextIds;
    if (changedSessionIds.length) this.revision += 1;
    return changedSessionIds;
  }

  snapshot(now = Date.now()) {
    this.pruneHistory(now);
    return {
      schemaVersion: MONITOR_SCHEMA_VERSION,
      monitorApiVersion: MONITOR_API_VERSION,
      // Additive: sessions, events, history, tasks, and inbox all participate.
      // An unchanged revision lets the client skip the expensive deep comparison.
      revision: this.revision,
      connected: this.connected,
      streaming: this.streaming,
      streamHealth: this.streamHealth,
      diagnostics: { ...this.diagnostics },
      error: this.lastError,
      gateway: this.gateway,
      sessions: [...this.sessions.values()],
      events: Object.fromEntries(this.eventsBySession),
      historySessions: [...this.historySessions.values()],
      historyEvents: Object.fromEntries(this.historyEventsBySession),
      eventLimit: this.maxEventsPerSession,
      tasks: this.tasks,
      inbox: this.inbox
    };
  }

  archiveSession(sessionId) {
    const session = this.sessions.get(sessionId) ?? this.historySessions.get(sessionId);
    const currentEvents = this.eventsBySession.get(sessionId) ?? [];
    if (!session || !currentEvents.length) return;
    this.historySessions.set(sessionId, session);
    const merged = [...(this.historyEventsBySession.get(sessionId) ?? []), ...currentEvents];
    const unique = new Map(merged.map((event) => [eventIdentity(event), event]));
    this.historyEventsBySession.set(sessionId, [...unique.values()]
      .sort(eventOrder)
      .slice(-this.maxEventsPerSession));
    this.historyExpiresAt.set(sessionId, Date.now() + this.historyRetentionMs);
  }

  pruneHistory(now = Date.now()) {
    let pruned = false;
    for (const [sessionId, expiresAt] of this.historyExpiresAt) {
      if (expiresAt > now) continue;
      this.historySessions.delete(sessionId);
      this.historyEventsBySession.delete(sessionId);
      this.historyExpiresAt.delete(sessionId);
      pruned = true;
    }
    if (pruned) this.revision += 1;
    return pruned;
  }

  restartBlockers() {
    const activeStatuses = new Set(["running", "waiting_permission", "waiting_input", "cancelling", "restoring"]);
    const activeSessions = [...this.sessions.values()]
      .filter((session) => session.source !== "local" && activeStatuses.has(session.status)).length;
    const activeTasks = this.tasks.filter((task) => ["working", "input_required"].includes(task.status)).length;
    const pendingInbox = this.inbox.filter((item) => item.status === "pending").length;
    return [
      ...(activeSessions ? [`진행 중 세션 ${activeSessions}개`] : []),
      ...(activeTasks ? [`진행 중 Task ${activeTasks}개`] : []),
      ...(pendingInbox ? [`미응답 Inbox ${pendingInbox}개`] : [])
    ];
  }

  broadcast(message) {
    const envelope = { ...message, schemaVersion: MONITOR_SCHEMA_VERSION, monitorApiVersion: MONITOR_API_VERSION };
    const frame = `data: ${JSON.stringify(envelope)}\n\n`;
    for (const client of this.sseClients) {
      try {
        if (client.write(frame)) continue;
      } catch {
        // A closed response is handled like a slow response below.
      }
      this.sseClients.delete(client);
      try {
        client.end();
      } catch {
        // The client is already gone.
      }
    }
  }
}

function eventIdentity(event) {
  if (Number.isFinite(event?.sequence)) return `sequence:${event.sequence}`;
  return `${event?.ts ?? ""}:${event?.type ?? ""}:${event?.turnId ?? ""}:${event?.text ?? ""}`;
}

function sessionMapSignature(map) {
  return JSON.stringify([...map.entries()]);
}

function externalEventsSignature(events) {
  const first = events[0];
  const last = events.at(-1);
  return JSON.stringify([
    events.length,
    first?.sequence, first?.type, first?.turnId, first?.text,
    last?.sequence, last?.type, last?.turnId, last?.text, last?.stopReason
  ]);
}

function eventOrder(left, right) {
  const leftSequence = Number.isFinite(left?.sequence) ? left.sequence : Infinity;
  const rightSequence = Number.isFinite(right?.sequence) ? right.sequence : Infinity;
  if (leftSequence !== rightSequence) return leftSequence - rightSequence;
  return String(left?.ts ?? "").localeCompare(String(right?.ts ?? ""));
}

export function queuedSingleFlight(operation) {
  let active = null;
  let queued = false;

  const run = () => {
    if (active) {
      queued = true;
      return active;
    }
    active = (async () => {
      try {
        return await operation();
      } finally {
        active = null;
        if (queued) {
          queued = false;
          void run().catch(() => {});
        }
      }
    })();
    return active;
  };

  return run;
}
