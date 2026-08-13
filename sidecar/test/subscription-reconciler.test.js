import assert from "node:assert/strict";
import test from "node:test";
import { GatewaySubscriptionOwner } from "../src/gateway/subscription-reconciler.js";
import { MonitorState } from "../src/projection/monitor-state.js";

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((nextResolve, nextReject) => {
    resolve = nextResolve;
    reject = nextReject;
  });
  return { promise, resolve, reject };
}

function seedSession(state, { sessionId = "s1", sequences = [0, 3] } = {}) {
  state.setConnection({ connected: true, streaming: true, error: null });
  state.setSessions([{ sessionId, status: "running" }]);
  for (const sequence of sequences) {
    state.pushEvent({ sessionId, sequence, type: sequence === 0 ? "turn_start" : "agent_message_chunk" });
  }
}

function createOwner({ rpc, state, onEvent = () => {}, applySessionSources, refresh }) {
  const owner = new GatewaySubscriptionOwner({
    rpc,
    state,
    onEvent,
    async applySessionSources() {
      if (applySessionSources) return applySessionSources();
      state.setSessions(state.gatewaySourceSessions);
    },
    async refresh() {
      if (refresh) return refresh();
    },
    isIgnoredEvent: (event) => event?.type === "subscription_gap" || event?.type === "subscription_replay_truncated"
  });
  return owner;
}

test("gap reconciliation keeps the old subscription live until rewind promote", async () => {
  const calls = [];
  const delivered = [];
  const state = new MonitorState();
  seedSession(state);
  state.beginSubscriptionGap({ sessionId: "s1", fromSequence: 1 });

  const oldEvents = [];
  let candidateOnEvent = null;
  const candidateGate = deferred();
  const rpc = {
    async unsubscribe(id) { calls.push(["unsubscribe", id]); },
    async subscribe(args, onEvent) {
      calls.push(["subscribe", args]);
      candidateOnEvent = onEvent;
      await candidateGate.promise;
      return {
        subscriptionId: "sub-new",
        sessions: [{ sessionId: "s1", status: "ready" }],
        events: [
          { sessionId: "s1", sequence: 2, type: "agent_message_chunk" },
          { sessionId: "s1", sequence: 1, type: "agent_message_chunk" },
          { sessionId: "s1", sequence: 3, type: "turn_completed" }
        ],
        cursorTruncated: { s1: false }
      };
    }
  };

  const owner = createOwner({
    rpc,
    state,
    onEvent(event) { delivered.push(event); }
  });
  owner.activeSubscriptionId = "sub-old";
  owner.subscriptionActive = true;
  owner.activeGeneration = 1;
  owner.nextGeneration = 1;
  owner.gapFloors = { s1: 1 };
  owner.onEvent = (event) => {
    delivered.push(event);
    oldEvents.push(event);
    if (event?.sessionId) state.pushEvent(event);
  };

  const reconcile = owner.reconcile();
  for (let attempt = 0; candidateOnEvent == null && attempt < 20; attempt += 1) await Promise.resolve();
  assert.equal(typeof candidateOnEvent, "function");
  assert.equal(owner.subscriptionActive, true, "old subscription stays active during candidate open");
  assert.equal(owner.activeSubscriptionId, "sub-old");
  owner.onEvent({ sessionId: "s1", sequence: 4, type: "agent_message_chunk", text: "old-live" });
  candidateOnEvent({ sessionId: "s1", sequence: 5, type: "agent_message_chunk", text: "candidate-live" });
  assert.equal(state.eventsBySession.get("s1").some((event) => event.sequence === 5), false);
  candidateGate.resolve();
  await reconcile;

  assert.deepEqual(calls.map(([name]) => name), ["subscribe", "unsubscribe"]);
  assert.equal(calls[0][1].cursors.s1, 1);
  assert.equal(calls[1][1], "sub-old");
  assert.equal(owner.activeSubscriptionId, "sub-new");
  assert.equal(owner.subscriptionActive, true);
  assert.deepEqual(state.snapshot().events.s1.map((event) => event.sequence), [0, 1, 2, 3, 4, 5]);
  assert.equal(state.snapshot().events.s1.some((event) => event.type === "subscription_gap"), false);
  assert.deepEqual(state.snapshot().diagnostics, {
    subscriptionGaps: 1,
    replayedEvents: 2,
    reconciliationRuns: 1,
    overflowDroppedEvents: 0,
    replayTruncations: 0
  });
  assert.equal(state.snapshot().streamHealth, "healthy");
  assert.equal(delivered.some((event) => event.sequence === 4), true);
  assert.equal(delivered.some((event) => event.sequence === 5), true);
  assert.equal(oldEvents.some((event) => event.sequence === 4), true);
});

test("candidate failure unsubscribes only the candidate and keeps the old subscription", async () => {
  const unsubscribed = [];
  const state = new MonitorState();
  seedSession(state);
  const rpc = {
    async unsubscribe(id) { unsubscribed.push(id); },
    async subscribe() {
      return { subscriptionId: "sub-new", sessions: [], events: [], cursorTruncated: {} };
    }
  };
  const owner = createOwner({
    rpc,
    state,
    async refresh() { throw new Error("refresh failed"); }
  });
  owner.activeSubscriptionId = "sub-old";
  owner.subscriptionActive = true;
  owner.activeGeneration = 1;
  owner.nextGeneration = 1;
  owner.gapFloors = { s1: 1 };

  await assert.rejects(() => owner.reconcile(), /refresh failed/);
  assert.deepEqual(unsubscribed, ["sub-new"]);
  assert.equal(owner.activeSubscriptionId, "sub-old");
  assert.equal(owner.subscriptionActive, true);
});

test("ensure during reconciliation opens exactly one rewind subscribe and leaks none", async () => {
  const subscribeCalls = [];
  const unsubscribed = [];
  const state = new MonitorState();
  seedSession(state);
  state.beginSubscriptionGap({ sessionId: "s1", fromSequence: 1 });
  const hold = deferred();
  const started = deferred();
  const rpc = {
    async unsubscribe(id) { unsubscribed.push(id); },
    async subscribe(args) {
      subscribeCalls.push(args);
      started.resolve();
      await hold.promise;
      return {
        subscriptionId: `sub-${subscribeCalls.length}`,
        sessions: [{ sessionId: "s1", status: "ready" }],
        events: [{ sessionId: "s1", sequence: 1, type: "agent_message_chunk" }],
        cursorTruncated: {}
      };
    }
  };
  const owner = createOwner({ rpc, state });
  owner.activeSubscriptionId = "sub-old";
  owner.subscriptionActive = true;
  owner.activeGeneration = 1;
  owner.nextGeneration = 1;
  owner.gapFloors = { s1: 1 };

  const reconcile = owner.reconcile();
  await started.promise;
  const ensure = owner.ensure();
  hold.resolve();
  await Promise.all([reconcile, ensure]);

  assert.equal(subscribeCalls.length, 1);
  assert.deepEqual(subscribeCalls[0].cursors, { s1: 1 });
  assert.equal(Math.min(4, 1), subscribeCalls[0].cursors.s1);
  assert.equal(owner.activeSubscriptionId, "sub-1");
  assert.deepEqual(unsubscribed, ["sub-old"]);
  assert.equal(unsubscribed.includes("sub-1"), false);
});

test("cursorTruncated after rewind degrades health and stays out of the timeline", async () => {
  const state = new MonitorState();
  seedSession(state);
  const rpc = {
    async unsubscribe() {},
    async subscribe() {
      return {
        subscriptionId: "sub-new",
        sessions: [{ sessionId: "s1", status: "ready" }],
        events: [{ sessionId: "s1", sequence: 1, type: "agent_message_chunk" }],
        cursorTruncated: { s1: true }
      };
    }
  };
  const owner = createOwner({ rpc, state });
  owner.activeSubscriptionId = "sub-old";
  owner.subscriptionActive = true;
  owner.activeGeneration = 1;
  owner.nextGeneration = 1;
  owner.gapFloors = { s1: 1 };

  await owner.reconcile();
  const snapshot = state.snapshot();
  assert.equal(snapshot.streamHealth, "degraded");
  assert.match(snapshot.error ?? "", /truncated/);
  assert.equal(snapshot.streaming, true);
  assert.equal(snapshot.diagnostics.replayTruncations, 1);
  assert.equal(snapshot.events.s1.some((event) => event.type === "subscription_replay_truncated"), false);
});

test("initial open unsubscribes a candidate if post-subscribe work fails", async () => {
  const unsubscribed = [];
  const state = new MonitorState();
  const rpc = {
    async unsubscribe(id) { unsubscribed.push(id); },
    async subscribe() {
      return {
        subscriptionId: "sub-leak",
        sessions: [{ sessionId: "s1", status: "ready" }],
        events: [],
        cursorTruncated: {}
      };
    }
  };
  const owner = createOwner({
    rpc,
    state,
    async applySessionSources() { throw new Error("apply failed"); }
  });

  await assert.rejects(() => owner.ensure(), /apply failed/);
  assert.deepEqual(unsubscribed, ["sub-leak"]);
  assert.equal(owner.subscriptionActive, false);
  assert.equal(owner.activeSubscriptionId, null);
});
