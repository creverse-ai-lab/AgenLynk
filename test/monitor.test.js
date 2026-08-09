import assert from "node:assert/strict";
import test from "node:test";
import { MonitorState, queuedSingleFlight } from "../src/monitor-state.js";

test("queuedSingleFlight serializes overlapping refreshes and coalesces the queue", async () => {
  let releaseFirst;
  const firstGate = new Promise((resolve) => { releaseFirst = resolve; });
  let calls = 0;
  let concurrent = 0;
  let maxConcurrent = 0;
  const refresh = queuedSingleFlight(async () => {
    calls += 1;
    concurrent += 1;
    maxConcurrent = Math.max(maxConcurrent, concurrent);
    if (calls === 1) await firstGate;
    concurrent -= 1;
  });

  const first = refresh();
  refresh();
  refresh();
  assert.equal(calls, 1);
  releaseFirst();
  await first;
  for (let attempt = 0; calls < 2 && attempt < 10; attempt += 1) {
    await new Promise((resolve) => setImmediate(resolve));
  }
  assert.equal(calls, 2, "overlapping requests should queue exactly one follow-up refresh");
  assert.equal(maxConcurrent, 1, "refreshes must never overlap");
});

test("MonitorState deduplicates, bounds events, and immediately removes missing sessions", () => {
  const state = new MonitorState({ maxEventsPerSession: 2 });
  state.setSessions([{ sessionId: "session-a" }]);
  assert.equal(state.pushEvent({ sessionId: "session-a", sequence: 0, type: "first" }), true);
  assert.equal(state.pushEvent({ sessionId: "session-a", sequence: 0, type: "duplicate" }), false);
  state.pushEvent({ sessionId: "session-a", sequence: 1, type: "second" });
  state.pushEvent({ sessionId: "session-a", sequence: 2, type: "third" });
  assert.deepEqual(state.snapshot().events["session-a"].map((event) => event.sequence), [1, 2]);
  assert.equal(state.snapshot().eventLimit, 2);
  assert.equal(state.snapshot().streaming, false);

  state.setSessions([]);
  assert.deepEqual(state.snapshot().events, {});
  assert.deepEqual(state.snapshot().historyEvents["session-a"].map((event) => event.sequence), [1, 2]);
});

test("MonitorState marks a close event and removes its Live data on removal", () => {
  const state = new MonitorState();
  state.setSessions([{ sessionId: "session-a", status: "idle", provider: "codex" }]);
  state.pushEvent({
    sessionId: "session-a",
    sequence: 0,
    type: "turn_start",
    ts: "2026-08-07T00:09:00.000Z",
    text: "show this prompt"
  });
  state.pushEvent({
    sessionId: "session-a",
    sequence: 1,
    type: "session_closed",
    ts: "2026-08-07T00:09:10.000Z"
  });
  assert.equal(state.snapshot().sessions[0].status, "closed");
  state.removeSession("session-a", { closed: true });
  assert.deepEqual(state.snapshot().sessions, []);
  assert.deepEqual(state.snapshot().events, {});
  assert.equal(state.snapshot().historySessions[0].sessionId, "session-a");
  state.setSessions([{ sessionId: "session-a", status: "idle", provider: "codex" }]);
  assert.deepEqual(state.snapshot().sessions, [], "a stale refresh must not resurrect an explicitly closed session");
});

test("MonitorState broadcasts gateway changes and drops slow SSE clients", () => {
  const state = new MonitorState();
  assert.equal(state.setGateway({ gatewayVersion: "1.0.0" }), true);
  assert.equal(state.setGateway({ gatewayVersion: "1.0.0" }), false);
  let ended = false;
  const slowClient = {
    write() { return false; },
    end() { ended = true; }
  };
  state.sseClients.add(slowClient);
  state.broadcast({ kind: "state" });
  assert.equal(ended, true);
  assert.equal(state.sseClients.size, 0);
});

test("MonitorState blocks Gateway restart while work or inbox responses are active", () => {
  const state = new MonitorState();
  state.setSessions([
    { sessionId: "running", status: "running" },
    { sessionId: "idle", status: "idle" }
  ]);
  state.tasks = [{ status: "working" }, { status: "completed" }];
  state.inbox = [{ status: "pending" }, { status: "answered" }];
  assert.deepEqual(state.restartBlockers(), [
    "진행 중 세션 1개",
    "진행 중 Task 1개",
    "미응답 Inbox 1개"
  ]);
  state.setSessions([{ sessionId: "idle", status: "idle" }]);
  state.tasks = [];
  state.inbox = [];
  assert.deepEqual(state.restartBlockers(), []);
});

test("MonitorState replaces local events and ignores local work as a Gateway restart blocker", () => {
  const state = new MonitorState();
  state.setSessions([{ sessionId: "local:codex:main", source: "local", status: "running" }]);
  state.setExternalEvents({
    "local:codex:main": [{ sessionId: "local:codex:main", sequence: 10, type: "turn_start" }]
  });
  assert.equal(state.snapshot().events["local:codex:main"].length, 1);
  assert.deepEqual(state.restartBlockers(), []);
  const unchangedRevision = state.revision;
  state.setExternalEvents({
    "local:codex:main": [{ sessionId: "local:codex:main", sequence: 10, type: "turn_start" }]
  });
  assert.equal(state.revision, unchangedRevision, "an unchanged local transcript must not churn monitor state");
  state.setExternalEvents({
    "local:codex:main": [{ sessionId: "local:codex:main", sequence: 12, type: "turn_start" }]
  });
  assert.deepEqual(state.snapshot().events["local:codex:main"].map((event) => event.sequence), [12]);
});
