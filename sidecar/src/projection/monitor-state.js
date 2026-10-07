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

const LOCAL_ACTIVE_STATUSES = new Set(["running", "waiting_permission", "waiting_input"]);

/**
 * A local session leaves the live list only once it is over: its SessionEnd
 * hook came, its process exited, or it went stale. Whatever turn it last
 * showed is over too, so history keeps it as idle rather than frozen mid-turn
 * (a SessionEnd can beat the transcript's own turn end to the scan).
 * A Gateway session is closed by its own session_closed event, which may come
 * after the list that no longer names it (see removeSession).
 */
function settledLocalSession(session) {
  if (session.source !== "local" || !LOCAL_ACTIVE_STATUSES.has(session.status)) return session;
  return {
    ...session,
    status: "idle",
    turnId: null,
    stopReason: "completed",
    turnUsage: Array.isArray(session.turnUsage)
      ? session.turnUsage.map((turn) => (turn?.running
        ? { ...turn, running: false, endedAt: turn.endedAt ?? session.updatedAt ?? null }
        : turn))
      : session.turnUsage
  };
}

export const MONITOR_API_VERSION = "2.0";
const MAX_PENDING_SSE_FRAMES = 512;
const MAX_PENDING_SSE_BYTES = 4 * 1024 * 1024;
// Remembered Gateway event identities per session, for replay dedupe only
// (a replay starts at the session's cursor, so recent identities suffice).
const MAX_GATEWAY_IDENTITIES = 4_000;
// Newest events per session a snapshot (and a reconcile frame) carries; older
// ones are paged from /api/sessions/:id/events.
const DEFAULT_SNAPSHOT_EVENT_LIMIT = 200;

// Whether a state frame carries data rather than only status; see
// #enqueueSseFrame. A list that is present is data even when empty (it may
// clear the client's copy); removals and events only when there are some.
const carriesData = (envelope) => envelope.sessions !== undefined
  || envelope.tasks !== undefined
  || envelope.inbox !== undefined
  || Boolean(envelope.historyCleared)
  || (envelope.removedSessionIds?.length ?? 0) > 0
  || Object.keys(envelope.events ?? {}).length > 0;

export class MonitorState {
  constructor({
    maxEventsPerSession = 2000,
    snapshotEventLimit = DEFAULT_SNAPSHOT_EVENT_LIMIT,
    historyRetentionMs = 65 * 60 * 1000,
    sseBackpressureTimeoutMs = 10_000,
    persistence = null,
    formerWorkerIds = [],
    onWorkerRemembered = null
  } = {}) {
    this.maxEventsPerSession = maxEventsPerSession;
    this.snapshotEventLimit = Math.min(snapshotEventLimit, maxEventsPerSession);
    this.snapshotCache = null;
    this.historyRetentionMs = historyRetentionMs;
    this.persistence = persistence;
    this.store = new EventStore({ maxEventsPerSession, persistence });
    this.sessions = new Map();
    // Bumped whenever the session list or a session record changes, so a
    // state frame carries the list only when there is something new in it.
    this.sessionsVersion = 0;
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
    // Kept on disk apart from history (onWorkerRemembered), so neither a
    // restart nor a zero history retention forgets a worker.
    this.formerWorkerIds = new Set(formerWorkerIds);
    this.onWorkerRemembered = onWorkerRemembered;
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
      .map((session) => [session.sessionId, this.#keepKnownParent(session)]));
    for (const [sessionId, session] of nextSessions) {
      nextSessions.set(sessionId, this.#openerFromAncestors(session, nextSessions));
    }
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
    if (changed) {
      this.revision += 1;
      this.sessionsVersion += 1;
    }
    return removedSessionIds;
  }

  /**
   * A local session's parent, once seen, is never dropped: the proof comes
   * and goes with processes and hook sessions (a finished `grok -p` parent
   * leaves the scan), and losing it turned a Worker back into a Frontdoor.
   */
  #keepKnownParent(session) {
    if (session.source !== "local" || session.parentSessionId) return session;
    const previous = this.sessions.get(session.sessionId) ?? this.historySessions.get(session.sessionId);
    if (!previous?.parentSessionId) return session;
    return {
      ...session,
      role: "worker",
      // The group it belongs to follows the parent (the app groups by opener).
      opener: previous.opener ?? session.opener,
      openerInstanceId: previous.openerInstanceId ?? session.openerInstanceId,
      parentSessionId: previous.parentSessionId,
      parentLocalSessionId: previous.parentLocalSessionId ?? session.parentLocalSessionId ?? null,
      ...(previous.parentProof ? { parentProof: previous.parentProof } : {})
    };
  }

  /**
   * A local Worker's opener is its topmost known ancestor's: the scan only
   * sees the parents still running, so a sub-agent of a finished `claude -p`
   * would otherwise name that `claude -p` as its Frontdoor.
   */
  #openerFromAncestors(session, live) {
    if (session.source !== "local" || !session.parentSessionId) return session;
    let top = session;
    const seen = new Set([session.sessionId]);
    while (top.parentSessionId && !seen.has(top.parentSessionId)) {
      seen.add(top.parentSessionId);
      const parent = live.get(top.parentSessionId) ?? this.historySessions.get(top.parentSessionId);
      if (!parent) break;
      top = parent;
    }
    if (top === session || !top.openerInstanceId || top.openerInstanceId === session.openerInstanceId) return session;
    return { ...session, opener: top.opener ?? session.opener, openerInstanceId: top.openerInstanceId };
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
      this.onWorkerRemembered?.(this.formerWorkerIds);
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
      const archived = closed ? { ...session, status: "closed" } : settledLocalSession(session);
      this.historySessions.set(sessionId, archived);
      this.historyExpiresAt.set(sessionId, Date.now() + this.historyRetentionMs);
      this.persistence?.writeSession(archived);
    } else if (closed && this.historySessions.has(sessionId) && this.historySessions.get(sessionId).status !== "closed") {
      // The list dropped it first; the close that follows is still news.
      const archived = { ...this.historySessions.get(sessionId), status: "closed" };
      this.historySessions.set(sessionId, archived);
      this.persistence?.writeSession(archived);
      this.revision += 1;
    } else if (!this.historySessions.has(sessionId)) {
      // Never listed (events that beat the session list, then its close):
      // no history row would ever expire these, so they go now. Whatever was
      // persisted stays on disk.
      this.#forgetEvents(sessionId);
    }
    if (this.sessions.delete(sessionId)) this.sessionsVersion += 1;
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
      this.sessionsVersion += 1;
      this.sessions.set(sessionId, {
        ...this.sessions.get(sessionId),
        status: "closed",
        updatedAt: event.ts ?? this.sessions.get(sessionId).updatedAt
      });
    }
    if (replay) this.diagnostics.replayedEvents += 1;
    if (changed.length) this.revision += 1;
    // A closed status can move without a revision bump.
    else if (event.type === "session_closed") this.snapshotCache = null;
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

  /**
   * The snapshot serialized, cached per revision: the app polls it and every
   * reconnect fetches it, and nothing in it changes without a revision bump.
   */
  snapshotJson(now = Date.now()) {
    this.pruneHistory(now);
    // Diagnostics counters may move without a revision bump; they are tiny.
    const key = `${this.revision}:${JSON.stringify(this.diagnostics)}`;
    if (this.snapshotCache?.key !== key) {
      this.snapshotCache = { key, json: JSON.stringify(this.snapshot(now)) };
    }
    return this.snapshotCache.json;
  }

  snapshot(now = Date.now()) {
    this.pruneHistory(now);
    // Only each session's newest events: the full memory window per session
    // made every poll megabytes. Older ones page from the events endpoint.
    const limit = this.snapshotEventLimit;
    const eventsOf = (ids) => Object.fromEntries(ids
      .map((sessionId) => [sessionId, this.store.list(sessionId, { limit })])
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
      // Additive: how many newest events per session `events` and
      // `historyEvents` carry at most.
      snapshotEventLimit: limit,
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
      if (session.source !== "local") {
        this.#rememberWorker(session);
        // The proof of a worker's parent (its Main's transcript) is often gone
        // by the next start, while the Gateway still lists the worker: without
        // its recorded topology the first merge would rewrite it unattributed.
        if (session.openerInstanceId && !this.workerTopology.has(session.sessionId)) {
          this.workerTopology.set(session.sessionId, {
            opener: session.opener ?? null,
            openerInstanceId: session.openerInstanceId,
            parentSessionId: session.parentSessionId ?? null
          });
        }
      }
      const events = this.persistence.readEvents(session.sessionId, { limit: this.maxEventsPerSession });
      // Rows written before empty hook-only sessions were held back (a usage
      // probe's bare SessionStart/SessionEnd) must not come back as Frontdoors.
      if (isEmptyHookOnlySession(session, events)) continue;
      this.historySessions.set(session.sessionId, session);
      this.historyExpiresAt.set(session.sessionId, now + this.historyRetentionMs);
      this.store.load(session.sessionId, events);
      restored += 1;
    }
    if (restored) this.revision += 1;
    return restored;
  }

  #forgetEvents(sessionId) {
    this.store.evict(sessionId);
    this.gatewaySeen.delete(sessionId);
    this.gatewayCursors.delete(sessionId);
    // With its timeline gone a normalizer has nothing left to pair against;
    // kept, one per expired orphan session piled up for good.
    this.gatewayNormalizers.delete(sessionId);
  }

  /** Forgets every history session (the user cleared the history). */
  clearHistory() {
    for (const sessionId of this.historySessions.keys()) {
      if (this.sessions.has(sessionId)) continue;
      this.#forgetEvents(sessionId);
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
      if (!this.sessions.has(sessionId)) this.#forgetEvents(sessionId);
      pruned = true;
    }
    // Orphans: events for a session that is neither live nor history (Gateway
    // events that beat a session list which never named them). They get the
    // same clock as history, counted from their last event.
    for (const sessionId of this.store.sessionIds()) {
      if (this.sessions.has(sessionId) || this.historySessions.has(sessionId)) continue;
      if ((this.store.idleMs(sessionId, now) ?? 0) <= this.historyRetentionMs) continue;
      this.#forgetEvents(sessionId);
      pruned = true;
    }
    for (const sessionId of new Set([...this.gatewaySeen.keys(), ...this.gatewayCursors.keys()])) {
      if (this.sessions.has(sessionId) || this.historySessions.has(sessionId) || this.store.sessions.has(sessionId)) continue;
      this.gatewaySeen.delete(sessionId);
      this.gatewayCursors.delete(sessionId);
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
      ...(activeTasks ? [`진행 중 태스크 ${activeTasks}개`] : []),
      ...(pendingInbox ? [`미응답 요청 ${pendingInbox}개`] : [])
    ];
  }

  broadcast(message) {
    // Nobody listening: nothing to serialize (broadcasts keep no state).
    if (!this.sseClients.size) return;
    // Every frame says how far the state had come, so the app can tell a
    // snapshot fetched meanwhile that is older than what it already applied.
    const envelope = { revision: this.revision, ...message, schemaVersion: MONITOR_SCHEMA_VERSION, monitorApiVersion: MONITOR_API_VERSION };
    const frame = `data: ${JSON.stringify(envelope)}\n\n`;
    const supersedable = envelope.kind === "state" && !carriesData(envelope);
    for (const client of this.sseClients) {
      const pending = this.sseBackpressure.get(client);
      if (pending) {
        if (!this.#enqueueSseFrame(pending, envelope.kind, frame, supersedable)) {
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

  #enqueueSseFrame(pending, kind, frame, supersedable) {
    // Only a state frame that carries nothing but status is superseded by the
    // next state frame. A frame with sessions, records or events is the only
    // copy of that change (later frames send the session list only when it
    // changes again), so it keeps its place like every other frame. The bounded
    // queue still evicts a client that cannot drain within a safe memory
    // budget; its reconnect begins with a snapshot.
    const last = pending.queue.at(-1);
    if (kind === "state" && last?.kind === "state" && last.supersedable) {
      pending.bytes -= Buffer.byteLength(last.frame);
      last.frame = frame;
      last.supersedable = supersedable;
      pending.bytes += Buffer.byteLength(frame);
    } else {
      pending.queue.push({ kind, frame, supersedable });
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
  let next = null;

  const start = () => {
    active = (async () => {
      try {
        return await operation();
      } finally {
        active = null;
      }
    })();
    return active;
  };

  // Overlapping callers share one pass queued after the running one, and get
  // its result: they asked because something changed, which the running pass
  // may have read too early to see.
  return () => {
    if (!active) return start();
    if (!next) {
      next = active.catch(() => {}).then(() => {
        next = null;
        return active ?? start();
      });
      // Callers often fire and forget; a failure is theirs to read, not a crash.
      next.catch(() => {});
    }
    return next;
  };
}

const LIFECYCLE_KINDS = new Set(["session_start", "session_end"]);

/** A local session nothing but its own start/end ever reached. */
export function isEmptyHookOnlySession(session, events) {
  if (session?.source !== "local" || session.title) return false;
  return (events ?? []).every((event) => LIFECYCLE_KINDS.has(event?.kind));
}
