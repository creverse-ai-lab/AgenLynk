export class MonitorState {
  constructor({ maxEventsPerSession = 2000 } = {}) {
    this.maxEventsPerSession = maxEventsPerSession;
    this.sessions = new Map();
    this.eventsBySession = new Map();
    this.eventSequencesBySession = new Map();
    this.closedSessionIds = new Set();
    this.closedSessionOrder = [];
    this.tasks = [];
    this.inbox = [];
    this.gateway = null;
    this.connected = false;
    this.streaming = false;
    this.lastError = null;
    this.sseClients = new Set();
  }

  setSessions(list) {
    const nextSessions = new Map(list
      .filter((session) => !this.closedSessionIds.has(session.sessionId))
      .map((session) => [session.sessionId, session]));
    const removedSessionIds = [...new Set([...this.sessions.keys(), ...this.eventsBySession.keys()])]
      .filter((sessionId) => !nextSessions.has(sessionId));
    for (const sessionId of removedSessionIds) this.removeSession(sessionId);
    this.sessions = nextSessions;
    return removedSessionIds;
  }

  removeSession(sessionId, { closed = false } = {}) {
    this.sessions.delete(sessionId);
    this.eventsBySession.delete(sessionId);
    this.eventSequencesBySession.delete(sessionId);
    if (closed && !this.closedSessionIds.has(sessionId)) {
      this.closedSessionIds.add(sessionId);
      this.closedSessionOrder.push(sessionId);
      if (this.closedSessionOrder.length > 2_000) {
        this.closedSessionIds.delete(this.closedSessionOrder.shift());
      }
    }
  }

  setGateway(gateway) {
    const changed = JSON.stringify(this.gateway) !== JSON.stringify(gateway);
    this.gateway = gateway;
    return changed;
  }

  pushEvent(event) {
    if (!event?.sessionId) return false;
    const events = this.eventsBySession.get(event.sessionId) ?? [];
    const sequences = this.eventSequencesBySession.get(event.sessionId) ?? new Set();
    if (Number.isFinite(event.sequence) && sequences.has(event.sequence)) return false;

    events.push(event);
    if (Number.isFinite(event.sequence)) sequences.add(event.sequence);
    if (events.length > this.maxEventsPerSession) {
      const removed = events.splice(0, events.length - this.maxEventsPerSession);
      for (const item of removed) {
        if (Number.isFinite(item.sequence)) sequences.delete(item.sequence);
      }
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
    return true;
  }

  snapshot() {
    return {
      connected: this.connected,
      streaming: this.streaming,
      error: this.lastError,
      gateway: this.gateway,
      sessions: [...this.sessions.values()],
      events: Object.fromEntries(this.eventsBySession),
      eventLimit: this.maxEventsPerSession,
      tasks: this.tasks,
      inbox: this.inbox
    };
  }

  restartBlockers() {
    const activeStatuses = new Set(["running", "waiting_permission", "waiting_input", "cancelling", "restoring"]);
    const activeSessions = [...this.sessions.values()].filter((session) => activeStatuses.has(session.status)).length;
    const activeTasks = this.tasks.filter((task) => ["working", "input_required"].includes(task.status)).length;
    const pendingInbox = this.inbox.filter((item) => item.status === "pending").length;
    return [
      ...(activeSessions ? [`진행 중 세션 ${activeSessions}개`] : []),
      ...(activeTasks ? [`진행 중 Task ${activeTasks}개`] : []),
      ...(pendingInbox ? [`미응답 Inbox ${pendingInbox}개`] : [])
    ];
  }

  broadcast(message) {
    const frame = `data: ${JSON.stringify(message)}\n\n`;
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
