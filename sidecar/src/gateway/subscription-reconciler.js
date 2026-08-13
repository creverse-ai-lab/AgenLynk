// Single owner for the monitor's Gateway event subscription.
// Make-before-break: the previous callback stays live until the candidate
// subscribe + rewind replay + refresh all succeed. Candidate live events are
// buffered and flushed only after promotion. A failed candidate is unsubscribed
// and the previous subscription stays active.

export class GatewaySubscriptionOwner {
  constructor({
    rpc,
    state,
    onEvent = () => {},
    applySessionSources,
    refresh,
    isIgnoredEvent = () => false
  } = {}) {
    this.rpc = rpc;
    this.state = state;
    this.onEvent = onEvent;
    this.applySessionSources = applySessionSources;
    this.refresh = refresh;
    this.isIgnoredEvent = isIgnoredEvent;
    this.activeSubscriptionId = null;
    this.activeGeneration = 0;
    this.nextGeneration = 0;
    this.subscriptionActive = false;
    this.reconciling = false;
    this.gapFloors = {};
    this.#candidate = null;
    this.#queue = Promise.resolve();
  }

  #candidate;
  #queue;

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
    return this.#runExclusive(async () => {
      if (this.reconciling) return this.status();
      this.reconciling = true;
      try {
        return await this.#replaceLossSafe();
      } finally {
        this.reconciling = false;
      }
    });
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
      if (this.#candidate?.generation === generation) this.#candidate.buffer.push(event);
    };
  }

  async #openInitial() {
    const generation = this.nextGeneration + 1;
    let subscription = null;
    this.#candidate = { generation, buffer: [], subscriptionId: null };
    try {
      subscription = await this.rpc.subscribe(
        { includeThoughts: true, includeToolEvents: true, cursors: {} },
        this.#bindCallback(generation)
      );
      this.#candidate.subscriptionId = subscription.subscriptionId;
      await this.#applyReplay(subscription);
      const truncated = truncatedSessionIds(subscription);
      this.#promote(generation, subscription.subscriptionId);
      this.#flushCandidate();
      this.#finishOpen({ truncated, reconciling: false });
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
    this.#candidate = { generation, buffer: [], subscriptionId: null };
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
      this.#flushCandidate();
      this.#consumeFloors(floors);
      this.state.completeReconciliation({ truncated: truncated.length > 0 });
      if (previousSubscriptionId && previousSubscriptionId !== subscription.subscriptionId) {
        await this.#unsubscribeQuiet(previousSubscriptionId);
      }
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

export function truncatedSessionIds(subscription) {
  return Object.entries(subscription?.cursorTruncated ?? {})
    .filter(([, value]) => value === true)
    .map(([sessionId]) => sessionId);
}
