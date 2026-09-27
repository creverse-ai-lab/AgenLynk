// Single owner for the monitor's Gateway event subscription.
// Make-before-break: the previous callback stays live until the candidate
// subscribe + rewind replay + refresh all succeed. Candidate live events are
// buffered and flushed only after promotion. A failed candidate is unsubscribed
// and the previous subscription stays active.

// Live events a candidate buffers before promotion. Past this the buffer is
// dropped and the lowest dropped sequence per session becomes a gap floor, so
// a follow-up reconciliation replays them instead of memory holding them.
export const MAX_CANDIDATE_BUFFER = 5_000;

export class GatewaySubscriptionOwner {
  constructor({
    rpc,
    state,
    onEvent = () => {},
    applySessionSources,
    refresh,
    isIgnoredEvent = () => false,
    maxCandidateBuffer = MAX_CANDIDATE_BUFFER
  } = {}) {
    this.rpc = rpc;
    this.state = state;
    this.onEvent = onEvent;
    this.applySessionSources = applySessionSources;
    this.refresh = refresh;
    this.isIgnoredEvent = isIgnoredEvent;
    this.maxCandidateBuffer = maxCandidateBuffer;
    this.activeSubscriptionId = null;
    this.activeGeneration = 0;
    this.nextGeneration = 0;
    this.subscriptionActive = false;
    this.reconciling = false;
    this.gapFloors = {};
    this.#candidate = null;
    this.#queue = Promise.resolve();
    this.#queuedReconcile = null;
  }

  #candidate;
  #queue;
  // A reconciliation queued but not yet started. Gap floors are read when a
  // run starts, so every gap noted before then is covered by that one run: a
  // burst of gap markers costs one running and at most one queued run.
  #queuedReconcile;

  status() {
    return {
      subscriptionId: this.activeSubscriptionId,
      active: this.subscriptionActive,
      generation: this.activeGeneration,
      reconciling: this.reconciling,
      candidateId: this.#candidate?.subscriptionId ?? null
    };
  }

  noteGap(event) {
    const gap = this.state.beginSubscriptionGap(event);
    if (gap.sessionId) {
      this.gapFloors[gap.sessionId] = Math.min(this.gapFloors[gap.sessionId] ?? Infinity, gap.fromSequence);
    }
    return gap;
  }

  markInactive() {
    this.subscriptionActive = false;
    this.activeSubscriptionId = null;
    this.activeGeneration += 1;
  }

  ensure() {
    return this.#runExclusive(async () => {
      if (this.subscriptionActive || this.reconciling) return this.status();
      return this.#openInitial();
    });
  }

  reconcile() {
    if (this.#queuedReconcile) return this.#queuedReconcile;
    const run = this.#runExclusive(async () => {
      if (this.#queuedReconcile === run) this.#queuedReconcile = null;
      if (this.reconciling) return this.status();
      this.reconciling = true;
      try {
        return await this.#replaceLossSafe();
      } finally {
        this.reconciling = false;
      }
    });
    this.#queuedReconcile = run;
    return run;
  }

  #runExclusive(operation) {
    const run = this.#queue.then(operation, operation);
    this.#queue = run.then(() => undefined, () => undefined);
    return run;
  }

  #bindCallback(generation) {
    return (event) => {
      if (this.activeGeneration === generation) {
        this.onEvent(event);
        return;
      }
      if (this.#candidate?.generation === generation) this.#buffer(this.#candidate, event);
    };
  }

  #buffer(candidate, event) {
    if (!candidate.overflowed) {
      candidate.buffer.push(event);
      if (candidate.buffer.length <= this.maxCandidateBuffer) return;
      candidate.overflowed = true;
      const dropped = candidate.buffer;
      candidate.buffer = [];
      for (const item of dropped) floorFor(candidate, item);
      return;
    }
    floorFor(candidate, event);
  }

  /** After an overflowed candidate: replay what it dropped, from its floors. */
  #recoverOverflow(candidate) {
    if (!candidate?.overflowed) return;
    for (const [sessionId, floor] of Object.entries(candidate.floors)) {
      this.gapFloors[sessionId] = Math.min(this.gapFloors[sessionId] ?? Infinity, floor);
    }
    void this.reconcile().catch(() => {});
  }

  async #openInitial() {
    const generation = this.nextGeneration + 1;
    let subscription = null;
    this.#candidate = { generation, buffer: [], subscriptionId: null, overflowed: false, floors: {} };
    try {
      subscription = await this.rpc.subscribe(
        { includeThoughts: true, includeToolEvents: true, cursors: {} },
        this.#bindCallback(generation)
      );
      this.#candidate.subscriptionId = subscription.subscriptionId;
      await this.#applyReplay(subscription);
      const truncated = truncatedSessionIds(subscription);
      this.#promote(generation, subscription.subscriptionId);
      const candidate = this.#candidate;
      this.#flushCandidate();
      this.#finishOpen({ truncated, reconciling: false });
      this.#recoverOverflow(candidate);
      return { subscription, cursors: {} };
    } catch (error) {
      await this.#abandonCandidate();
      throw error;
    }
  }

  async #replaceLossSafe() {
    const previousSubscriptionId = this.activeSubscriptionId;
    const generation = this.nextGeneration + 1;
    const floors = { ...this.gapFloors };
    const cursors = this.state.subscriptionCursors(floors);
    let subscription = null;
    this.#candidate = { generation, buffer: [], subscriptionId: null, overflowed: false, floors: {} };
    try {
      subscription = await this.rpc.subscribe(
        { includeThoughts: true, includeToolEvents: true, cursors },
        this.#bindCallback(generation)
      );
      this.#candidate.subscriptionId = subscription.subscriptionId;
      await this.#applyReplay(subscription);
      await this.refresh();
      const truncated = truncatedSessionIds(subscription);
      this.#promote(generation, subscription.subscriptionId);
      const candidate = this.#candidate;
      this.#flushCandidate();
      this.#consumeFloors(floors);
      this.state.completeReconciliation({ truncated: truncated.length > 0 });
      if (previousSubscriptionId && previousSubscriptionId !== subscription.subscriptionId) {
        await this.#unsubscribeQuiet(previousSubscriptionId);
      }
      this.#recoverOverflow(candidate);
      return { subscription, cursors };
    } catch (error) {
      await this.#abandonCandidate();
      throw error;
    }
  }

  async #applyReplay(subscription) {
    this.state.setGatewaySourceSessions(subscription.sessions ?? []);
    await this.applySessionSources();
    for (const event of subscription.events ?? []) {
      if (!this.isIgnoredEvent(event)) this.state.pushEvent(event, { replay: true });
    }
    const truncated = truncatedSessionIds(subscription);
    if (truncated.length) this.state.noteReplayTruncation({ sessionIds: truncated });
  }

  #promote(generation, subscriptionId) {
    this.activeGeneration = generation;
    this.nextGeneration = generation;
    this.activeSubscriptionId = subscriptionId;
    this.subscriptionActive = true;
  }

  #flushCandidate() {
    const buffered = this.#candidate?.buffer ?? [];
    this.#candidate = null;
    for (const event of buffered) this.onEvent(event);
  }

  async #abandonCandidate() {
    const candidateId = this.#candidate?.subscriptionId;
    this.#candidate = null;
    if (candidateId && candidateId !== this.activeSubscriptionId) {
      await this.#unsubscribeQuiet(candidateId);
    }
  }

  #consumeFloors(floors) {
    for (const [key, floor] of Object.entries(floors)) {
      if (this.gapFloors[key] === floor) delete this.gapFloors[key];
    }
  }

  #finishOpen({ truncated, reconciling }) {
    if (reconciling) {
      this.state.completeReconciliation({ truncated: truncated.length > 0 });
      return;
    }
    if (truncated.length) {
      if (this.state.streamHealth !== "degraded") {
        this.state.noteReplayTruncation({ sessionIds: truncated });
      }
      return;
    }
    this.state.setConnection({ connected: true, streaming: true, error: null, health: "healthy" });
  }

  async #unsubscribeQuiet(subscriptionId) {
    try {
      await this.rpc.unsubscribe(subscriptionId);
    } catch {
      // The server may already have dropped it.
    }
  }
}

function floorFor(candidate, event) {
  if (!event?.sessionId || !Number.isFinite(event.sequence)) return;
  candidate.floors[event.sessionId] = Math.min(candidate.floors[event.sessionId] ?? Infinity, event.sequence);
}

export function truncatedSessionIds(subscription) {
  return Object.entries(subscription?.cursorTruncated ?? {})
    .filter(([, value]) => value === true)
    .map(([sessionId]) => sessionId);
}
