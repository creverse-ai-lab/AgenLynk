import assert from "node:assert/strict";
import test from "node:test";
import { MonitorState } from "../src/monitor-state.js";
import { isIgnoredMonitorEvent } from "../src/monitor.js";

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
