import { GatewayEventNormalizer } from "../normalize/acp.js";
import { EventStore } from "../store/event-store.js";

// Wire contract for the native Monitor app's HTTP/SSE API, independent of
// GATEWAY_API_VERSION (the Gateway daemon's own setup/subscribe handshake).
// Bump MONITOR_SCHEMA_VERSION only when a field is removed, renamed, or
// changes meaning; additive fields do not require a bump.
//
// v2: events are canonical (contracts/monitor/v2): `kind` instead of the
// source's `type`, a store-assigned `sequence`, a stable `id`, and the same
// shape whether the Gateway, a transcript, or a hook produced them.
export const MONITOR_SCHEMA_VERSION = 2;
export const MONITOR_API_VERSION = "2.0";
const MAX_PENDING_SSE_FRAMES = 512;
const MAX_PENDING_SSE_BYTES = 4 * 1024 * 1024;
// Remembered Gateway event identities per session, for replay dedupe.
const MAX_GATEWAY_IDENTITIES = 20_000;

export class MonitorState {
  constructor({
    maxEventsPerSession = 2000,
    historyRetentionMs = 65 * 60 * 1000,
    sseBackpressureTimeoutMs = 10_000,
    persistence = null
  } = {}) {
    this.maxEventsPerSession = maxEventsPerSession;
    this.historyRetentionMs = historyRetentionMs;
    this.persistence = persistence;
    this.store = new EventStore({ maxEventsPerSession, persistence });
    this.sessions = new Map();
    this.sessionSignatures = new Map();
    // Raw Gateway session source retained inside the canonical state owner so
    // transport callbacks do not maintain a competing module-level copy.
    this.gatewaySourceSessions = [];
    // Proven Frontdoor/Worker topology per Gateway session. The transcript
    // that proves a worker's parent goes stale right after its turn ends, so
    // the merge keeps the last proven attribution here for the session's
    // lifetime (see mergeMonitorSessions).
    this.workerTopology = new Map();
    // Every provider-side id the Gateway has ever reported. A worker's own
    // transcript outlives its Gateway session (idle sessions stay listed for
    // the retention window), and without this it would come back as a
    // parentless local session — a false Frontdoor.
    this.formerWorkerIds = new Set();
    // Gateway subscription bookkeeping: one stateful normalizer per session
    // (chunks stream one at a time), the highest daemon sequence seen (the
    // resubscribe cursor), and the identities already applied. The identity
    // includes ts, so a restarted daemon that renumbers from 0 is not
    // mistaken for a replay of what the monitor already holds.
    this.gatewayNormalizers = new Map();
    this.gatewayCursors = new Map();
    this.gatewaySeen = new Map();
    this.historySessions = new Map();
    this.historyExpiresAt = new Map();
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
    this.sseBackpressure = new Map();
    this.sseBackpressureTimeoutMs = sseBackpressureTimeoutMs;
    this.revision = 0;
  }

  addSseClient(client) {
    this.sseClients.add(client);
  }

  removeSseClient(client, { end = false } = {}) {
    this.sseClients.delete(client);
    const pending = this.sseBackpressure.get(client);
    if (pending) {
      clearTimeout(pending.timer);
      this.sseBackpressure.delete(client);
    }
    if (!end) return;
    try {
      client.end();
    } catch {
      // The response is already closed.
    }
  }

  closeSseClients() {
    for (const client of [...this.sseClients]) this.removeSseClient(client, { end: true });
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
      .filter((session) => session && typeof session === "object"
        && typeof session.sessionId === "string" && session.sessionId
        && !this.closedSessionIds.has(session.sessionId))
      .map((session) => [session.sessionId, session]));
    const removedSessionIds = [...this.sessions.keys()].filter((sessionId) => !nextSessions.has(sessionId));
    for (const sessionId of removedSessionIds) this.removeSession(sessionId);
    let changed = removedSessionIds.length > 0;
    const nextSignatures = new Map();
    for (const [sessionId, session] of nextSessions) {
      const signature = JSON.stringify(session);
      nextSignatures.set(sessionId, signature);
      if (this.sessionSignatures.get(sessionId) === signature) continue;
      changed = true;
      this.persistence?.writeSession(session);
      // A session that came back is live again, not history.
      this.historySessions.delete(sessionId);
      this.historyExpiresAt.delete(sessionId);
    }
    this.sessions = nextSessions;
    this.sessionSignatures = nextSignatures;
    if (changed) this.revision += 1;
    return removedSessionIds;
  }

  setGatewaySourceSessions(list) {
    this.gatewaySourceSessions = Array.isArray(list) ? list : [];
    for (const session of this.gatewaySourceSessions) this.#rememberWorker(session);
  }

  #rememberWorker(session) {
    for (const id of [session?.sessionId, session?.acpSessionId]) {
      if (typeof id !== "string" || !id || this.formerWorkerIds.has(id)) continue;
      this.formerWorkerIds.add(id);
      if (this.formerWorkerIds.size > 10_000) this.formerWorkerIds.delete(this.formerWorkerIds.values().next().value);
    }
  }

  /**
   * Moves a live session to history. Its events stay in the store (and in the
   * persisted history), so nothing has to be copied.
   */
  removeSession(sessionId, { closed = false } = {}) {
    const session = this.sessions.get(sessionId);
    const existed = Boolean(session) || this.store.has(sessionId);
    if (session) {
      const archived = closed ? { ...session, status: "closed" } : session;
      this.historySessions.set(sessionId, archived);
      this.historyExpiresAt.set(sessionId, Date.now() + this.historyRetentionMs);
      this.persistence?.writeSession(archived);
    }
    this.sessions.delete(sessionId);
    this.sessionSignatures.delete(sessionId);
    this.workerTopology.delete(sessionId);
    this.gatewayNormalizers.delete(sessionId);
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

  /**
   * One Gateway subscription event. Returns the canonical events it changed
   * (empty when it was a duplicate or carried nothing to show).
   */
  pushEvent(event, { replay = false } = {}) {
    // Gap/truncation markers are subscription control records, never timeline content.
    if (!event?.sessionId || event.type === "subscription_gap" || event.type === "subscription_replay_truncated") {
      return [];
    }
    const sessionId = event.sessionId;
    // The daemon stamps every event; sequence + ts tells a replay (same pair)
    // from a restarted daemon's renumbered event (same sequence, later ts).
    const identity = `${event.sequence ?? ""}:${event.ts ?? ""}`;
    let seen = this.gatewaySeen.get(sessionId);
    if (!seen) {
      seen = new Set();
      this.gatewaySeen.set(sessionId, seen);
    }
    if (Number.isFinite(event.sequence) && seen.has(identity)) return [];
    if (Number.isFinite(event.sequence)) {
      seen.add(identity);
      if (seen.size > MAX_GATEWAY_IDENTITIES) seen.delete(seen.values().next().value);
      this.gatewayCursors.set(sessionId, Math.max(this.gatewayCursors.get(sessionId) ?? -1, event.sequence));
    }
    let normalizer = this.gatewayNormalizers.get(sessionId);
    if (!normalizer) {
      normalizer = new GatewayEventNormalizer();
      this.gatewayNormalizers.set(sessionId, normalizer);
    }
    const before = this.store.overflowDropped;
    const changed = this.store.upsert(sessionId, normalizer.ingest(event));
    this.diagnostics.overflowDroppedEvents += this.store.overflowDropped - before;
    if (event.type === "session_closed" && this.sessions.has(sessionId)) {
      this.sessions.set(sessionId, {
        ...this.sessions.get(sessionId),
        status: "closed",
        updatedAt: event.ts ?? this.sessions.get(sessionId).updatedAt
      });
    }
    if (replay) this.diagnostics.replayedEvents += 1;
    if (changed.length) this.revision += 1;
    return changed;
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
    const sessionIds = new Set([...this.gatewayCursors.keys(), ...Object.keys(floors)]);
    return Object.fromEntries([...sessionIds].map((sessionId) => {
      const highest = this.gatewayCursors.get(sessionId);
      const next = Number.isFinite(highest) ? highest + 1 : 0;
      const floor = Number.isFinite(floors[sessionId]) ? floors[sessionId] : next;
      return [sessionId, Math.min(next, floor)];
    }));
  }

  snapshotTag(now = Date.now()) {
    this.pruneHistory(now);
    return `\"monitor-${this.revision}\"`;
  }

  /**
   * Canonical events from local timelines, grouped by session. Upserted, never
   * replaced: an event that slides out of a transcript window stays. Returns
   * only what changed, grouped the same way, for the SSE `events` frame.
   */
  setExternalEvents(groups = {}) {
    const changed = {};
    for (const [sessionId, values] of Object.entries(groups)) {
      const before = this.store.overflowDropped;
      const updated = this.store.upsert(sessionId, Array.isArray(values) ? values : []);
      this.diagnostics.overflowDroppedEvents += this.store.overflowDropped - before;
      if (updated.length) changed[sessionId] = updated;
    }
    if (Object.keys(changed).length) this.revision += 1;
    return changed;
  }

  /** Events for one session, oldest first. */
  eventsFor(sessionId, options) {
    return this.store.list(sessionId, options);
  }

  snapshot(now = Date.now()) {
    this.pruneHistory(now);
    const eventsOf = (ids) => Object.fromEntries(ids
      .map((sessionId) => [sessionId, this.store.list(sessionId)])
      .filter(([, events]) => events.length));
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
      // Gateway events can land before the session list that names them.
      events: eventsOf(this.store.sessionIds().filter((sessionId) => !this.historySessions.has(sessionId))),
      historySessions: [...this.historySessions.values()],
      historyEvents: eventsOf([...this.historySessions.keys()]),
      eventLimit: this.maxEventsPerSession,
      tasks: this.tasks,
      inbox: this.inbox
    };
  }

  /**
   * Loads recently active sessions from persisted history, so a sidecar
   * restart does not blank the log. Restored sessions are history until a
   * source reports them live again.
   */
  restoreHistory(now = Date.now()) {
    if (!this.persistence) return 0;
    let restored = 0;
    for (const session of this.persistence.readSessions({ since: now - this.historyRetentionMs })) {
      if (!session?.sessionId || this.sessions.has(session.sessionId)) continue;
      if (session.source !== "local") this.#rememberWorker(session);
      this.historySessions.set(session.sessionId, session);
      this.historyExpiresAt.set(session.sessionId, now + this.historyRetentionMs);
      this.store.load(session.sessionId, this.persistence.readEvents(session.sessionId, { limit: this.maxEventsPerSession }));
      restored += 1;
    }
    if (restored) this.revision += 1;
    return restored;
  }

  /** Forgets every history session (the user cleared the history). */
  clearHistory() {
    for (const sessionId of this.historySessions.keys()) {
      if (this.sessions.has(sessionId)) continue;
      this.store.evict(sessionId);
      this.gatewaySeen.delete(sessionId);
      this.gatewayCursors.delete(sessionId);
    }
    this.historySessions.clear();
    this.historyExpiresAt.clear();
    this.revision += 1;
  }

  pruneHistory(now = Date.now()) {
    let pruned = false;
    for (const [sessionId, expiresAt] of this.historyExpiresAt) {
      if (expiresAt > now) continue;
      this.historySessions.delete(sessionId);
      this.historyExpiresAt.delete(sessionId);
      // Memory only: the persisted history keeps the session for its own,
      // longer retention.
      if (!this.sessions.has(sessionId)) {
        this.store.evict(sessionId);
        this.gatewaySeen.delete(sessionId);
        this.gatewayCursors.delete(sessionId);
      }
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
      const pending = this.sseBackpressure.get(client);
      if (pending) {
        if (!this.#enqueueSseFrame(pending, envelope.kind, frame)) {
          this.removeSseClient(client, { end: true });
        }
        continue;
      }
      try {
        if (client.write(frame)) continue;
      } catch {
        this.removeSseClient(client, { end: true });
        continue;
      }
      this.#waitForSseDrain(client);
    }
  }

  #waitForSseDrain(client) {
    const onDrain = () => {
      const pending = this.sseBackpressure.get(client);
      if (!pending) return;
      clearTimeout(pending.timer);
      this.sseBackpressure.delete(client);
      this.#flushSseQueue(client, pending.queue);
    };
    const timer = setTimeout(() => {
      this.removeSseClient(client, { end: true });
    }, this.sseBackpressureTimeoutMs);
    timer.unref?.();
    this.sseBackpressure.set(client, { queue: [], bytes: 0, timer });
    if (typeof client.once === "function") {
      client.once("drain", onDrain);
    } else {
      // ServerResponse always exposes `once`; defensive fallback for custom
      // transports/tests that do not implement the writable stream contract.
      this.removeSseClient(client, { end: true });
    }
  }

  #enqueueSseFrame(pending, kind, frame) {
    // Only consecutive state snapshots supersede one another. Incremental
    // event/session/gateway frames retain order so backpressure never becomes
    // silent data loss. The bounded queue still evicts a client that cannot
    // drain within a safe memory budget; its reconnect begins with a snapshot.
    const last = pending.queue.at(-1);
    if (kind === "state" && last?.kind === "state") {
      pending.bytes -= Buffer.byteLength(last.frame);
      last.frame = frame;
      pending.bytes += Buffer.byteLength(frame);
    } else {
      pending.queue.push({ kind, frame });
      pending.bytes += Buffer.byteLength(frame);
    }
    return pending.queue.length <= MAX_PENDING_SSE_FRAMES && pending.bytes <= MAX_PENDING_SSE_BYTES;
  }

  #flushSseQueue(client, queue) {
    if (!this.sseClients.has(client)) return;
    while (queue.length) {
      const next = queue.shift();
      try {
        if (client.write(next.frame)) continue;
      } catch {
        this.removeSseClient(client, { end: true });
        return;
      }
      this.#waitForSseDrain(client);
      const pending = this.sseBackpressure.get(client);
      if (pending) {
        pending.queue = queue;
        pending.bytes = queue.reduce((total, item) => total + Buffer.byteLength(item.frame), 0);
      }
      return;
    }
  }
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
