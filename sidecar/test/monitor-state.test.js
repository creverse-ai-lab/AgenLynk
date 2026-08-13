import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import { MonitorState } from "../src/projection/monitor-state.js";
import { isIgnoredMonitorEvent } from "../src/server/monitor.js";

test("MonitorState produces the shared Monitor API v1 snapshot fixture", async () => {
  const fixtureUrl = new URL("./fixtures/monitor-snapshot-v1.json", import.meta.url);
  const fixture = JSON.parse(await readFile(fixtureUrl, "utf8"));
  const input = fixture._input;
  const state = new MonitorState();
  state.setGateway(input.gateway);
  state.setConnection({ connected: true, streaming: true, error: null });
  state.setSessions(input.initialSessions);
  for (const event of input.events) state.pushEvent(event);
  state.setSessions(input.finalSessions);
  state.setRecords({ tasks: input.tasks, inbox: input.inbox });

  const expected = { ...fixture };
  delete expected._comment;
  delete expected._input;
  assert.deepEqual(state.snapshot(), expected);
});

test("setExternalEvents reports only the local buckets that changed", () => {
  const state = new MonitorState();
  const first = [{ sessionId: "local:codex:a", sequence: 1, type: "turn_start" }];
  const second = [{ sessionId: "local:codex:b", sequence: 1, type: "turn_start" }];

  assert.deepEqual(state.setExternalEvents({ "local:codex:a": first, "local:codex:b": second }).sort(),
    ["local:codex:a", "local:codex:b"]);
  // The scanner re-reads the same transcript every second; an unchanged read
  // must not put the bucket back on the wire.
  assert.deepEqual(state.setExternalEvents({ "local:codex:a": first, "local:codex:b": second }), []);

  const grown = [...first, { sessionId: "local:codex:a", sequence: 2, type: "agent_message_chunk", text: "hi" }];
  assert.deepEqual(state.setExternalEvents({ "local:codex:a": grown, "local:codex:b": second }), ["local:codex:a"]);
  assert.deepEqual(state.eventsBySession.get("local:codex:a").map((event) => event.sequence), [1, 2]);

  // A dropped bucket is a change too: the app has to clear what it holds.
  assert.deepEqual(state.setExternalEvents({ "local:codex:a": grown }), ["local:codex:b"]);
  assert.equal(state.eventsBySession.has("local:codex:b"), false);
});

test("setExternalEvents replaces a rewritten turn instead of appending it", () => {
  const state = new MonitorState();
  state.setExternalEvents({ "local:codex:a": [{ sessionId: "local:codex:a", sequence: 1, type: "turn_start", turnId: null }] });
  const changed = state.setExternalEvents({
    "local:codex:a": [{ sessionId: "local:codex:a", sequence: 1, type: "turn_start", turnId: "turn-1" }]
  });
  assert.deepEqual(changed, ["local:codex:a"]);
  assert.deepEqual(state.eventsBySession.get("local:codex:a").map((event) => event.turnId), ["turn-1"]);
});

test("monitor ingestion drops usage_update from an old daemon's replay", () => {
  assert.equal(isIgnoredMonitorEvent({ type: "usage_update", sessionId: "s1" }), true);
  assert.equal(isIgnoredMonitorEvent({ type: "subscription_replay_truncated", sessionIds: ["s1"] }), true);
  assert.equal(isIgnoredMonitorEvent({ type: "agent_message_chunk", sessionId: "s1" }), false);
  assert.equal(isIgnoredMonitorEvent(undefined), false);

  // The replay path a pre-1.3.2 daemon serves on subscribe.
  const state = new MonitorState();
  const replay = [
    { sessionId: "s1", sequence: 1, type: "turn_start" },
    { sessionId: "s1", sequence: 2, type: "usage_update" },
    { sessionId: "s1", sequence: 3, type: "turn_completed" }
  ];
  for (const event of replay) {
    if (isIgnoredMonitorEvent(event)) continue;
    state.pushEvent(event);
  }
  assert.deepEqual(state.snapshot().events.s1.map((event) => event.type), ["turn_start", "turn_completed"]);
});

test("replay truncation degrades health, increments diagnostics, and stays out of the timeline", () => {
  const state = new MonitorState();
  state.setConnection({ connected: true, streaming: true, error: null });
  state.pushEvent({ sessionId: "s1", sequence: 0, type: "turn_start" });
  assert.equal(state.pushEvent({ type: "subscription_replay_truncated", sessionIds: ["s1"] }), false);
  state.noteReplayTruncation({ type: "subscription_replay_truncated", sessionIds: ["s1"] });
  const snapshot = state.snapshot();
  assert.equal(snapshot.streamHealth, "degraded");
  assert.equal(snapshot.streaming, true);
  assert.match(snapshot.error ?? "", /truncated/);
  assert.equal(snapshot.diagnostics.replayTruncations, 1);
  assert.equal(snapshot.events.s1.some((event) => event.type === "subscription_replay_truncated"), false);
});

test("expired history changes the snapshot tag and yields a pruned body", () => {
  const state = new MonitorState({ historyRetentionMs: 1_000 });
  state.setSessions([{ sessionId: "old", provider: "codex", status: "ready" }]);
  state.pushEvent({ sessionId: "old", sequence: 1, type: "turn_end", ts: "2026-08-06T23:59:00.000Z" });
  state.setSessions([]);
  const expiresAt = state.historyExpiresAt.get("old");
  const liveNow = expiresAt - 1;
  const liveTag = state.snapshotTag(liveNow);
  const live = state.snapshot(liveNow);
  assert.equal(live.historySessions.length, 1);
  const expiredTag = state.snapshotTag(expiresAt + 1);
  assert.notEqual(expiredTag, liveTag);
  const pruned = state.snapshot(expiresAt + 1);
  assert.deepEqual(pruned.historySessions, []);
  assert.deepEqual(pruned.historyEvents, {});
  assert.ok(pruned.revision > live.revision);
});
