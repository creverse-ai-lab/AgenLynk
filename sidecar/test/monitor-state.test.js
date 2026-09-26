import assert from "node:assert/strict";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { monitorEvent } from "../src/normalize/model.js";
import { MonitorState } from "../src/projection/monitor-state.js";
import { isIgnoredMonitorEvent } from "../src/server/monitor.js";
import { SqliteMonitorStore } from "../src/store/sqlite-store.js";

test("MonitorState produces the shared Monitor API v2 snapshot fixture", async () => {
  const fixtureUrl = new URL("./fixtures/monitor-snapshot-v2.json", import.meta.url);
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

const localEvent = (key, ts, values = {}) => monitorEvent({
  key, kind: "agent_message", ts, source: "transcript", body: key, ...values
});

test("setExternalEvents upserts and reports only what changed", () => {
  const state = new MonitorState();
  const a = "local:codex:a";
  const window = [localEvent("m1", "2026-08-07T00:00:00Z"), localEvent("m2", "2026-08-07T00:00:01Z")];

  assert.deepEqual(Object.keys(state.setExternalEvents({ [a]: window })), [a]);
  // Re-normalizing the same window every scan tick must not hit the wire.
  assert.deepEqual(state.setExternalEvents({ [a]: window }), {});

  const refined = [window[0], localEvent("m2", "2026-08-07T00:00:01Z", { body: "m2 finished" })];
  const changed = state.setExternalEvents({ [a]: refined });
  assert.deepEqual(changed[a].map((event) => event.key), ["m2"]);
  assert.equal(state.eventsFor(a).at(-1).body, "m2 finished");
  assert.deepEqual(state.eventsFor(a).map((event) => event.sequence), [1, 2], "a refined event keeps its sequence");
});

test("events that slide out of a transcript window stay in the timeline", () => {
  const state = new MonitorState();
  const a = "local:codex:a";
  state.setSessions([{ sessionId: a, provider: "codex", status: "running" }]);
  state.setExternalEvents({ [a]: [localEvent("m1", "2026-08-07T00:00:00Z"), localEvent("m2", "2026-08-07T00:00:01Z")] });
  state.setExternalEvents({ [a]: [localEvent("m2", "2026-08-07T00:00:01Z"), localEvent("m3", "2026-08-07T00:00:02Z")] });
  assert.deepEqual(state.eventsFor(a).map((event) => event.key), ["m1", "m2", "m3"]);
  assert.equal(state.historySessions.has(a), false, "a live session is never copied into history");
});

test("a removed session moves to history with its events intact", () => {
  const state = new MonitorState();
  const a = "local:claude:a";
  state.setSessions([{ sessionId: a, provider: "claude", status: "running" }]);
  state.setExternalEvents({ [a]: [localEvent("m1", "2026-08-07T00:00:00Z")] });
  state.setSessions([]);
  const snapshot = state.snapshot();
  assert.deepEqual(snapshot.historySessions.map((session) => session.sessionId), [a]);
  assert.deepEqual(snapshot.historyEvents[a].map((event) => event.key), ["m1"]);
  assert.equal(snapshot.events[a], undefined);
});

test("Gateway chunks merge into one message and replays are ignored", () => {
  const state = new MonitorState();
  const chunk = (sequence, text, ts) => ({ sessionId: "s1", sequence, type: "agent_message_chunk", ts, turnId: "t1", text });
  state.pushEvent({ sessionId: "s1", sequence: 0, type: "turn_start", ts: "2026-08-07T00:00:00Z", turnId: "t1", text: "go" });
  state.pushEvent(chunk(1, "hel", "2026-08-07T00:00:01Z"));
  state.pushEvent(chunk(2, "lo", "2026-08-07T00:00:02Z"));
  assert.deepEqual(state.pushEvent(chunk(2, "lo", "2026-08-07T00:00:02Z"), { replay: true }), [], "a replayed chunk is not appended twice");
  const messages = state.eventsFor("s1").filter((event) => event.kind === "agent_message");
  assert.equal(messages.length, 1);
  assert.equal(messages[0].body, "hello");

  // A restarted daemon renumbers from 0: same sequence, different event.
  const restarted = state.pushEvent({ sessionId: "s1", sequence: 1, type: "turn_completed", ts: "2026-08-07T00:05:00Z", turnId: "t1" });
  assert.equal(restarted.length, 1, "a renumbered event is not mistaken for a replay");
  assert.deepEqual(state.subscriptionCursors(), { s1: 3 });
});

test("monitor ingestion drops usage_update from an old daemon's replay", () => {
  assert.equal(isIgnoredMonitorEvent({ type: "usage_update", sessionId: "s1" }), true);
  assert.equal(isIgnoredMonitorEvent({ type: "subscription_replay_truncated", sessionIds: ["s1"] }), true);
  assert.equal(isIgnoredMonitorEvent({ type: "agent_message_chunk", sessionId: "s1" }), false);
  assert.equal(isIgnoredMonitorEvent(undefined), false);

  // The replay path a pre-1.3.2 daemon serves on subscribe.
  const state = new MonitorState();
  const replay = [
    { sessionId: "s1", sequence: 1, type: "turn_start", ts: "2026-08-07T00:00:00Z", turnId: "t1" },
    { sessionId: "s1", sequence: 2, type: "usage_update", ts: "2026-08-07T00:00:01Z", turnId: "t1" },
    { sessionId: "s1", sequence: 3, type: "turn_completed", ts: "2026-08-07T00:00:02Z", turnId: "t1" }
  ];
  for (const event of replay) {
    if (isIgnoredMonitorEvent(event)) continue;
    state.pushEvent(event);
  }
  assert.deepEqual(state.snapshot().events.s1.map((event) => event.kind), ["turn_start", "turn_end"]);
});

test("replay truncation degrades health, increments diagnostics, and stays out of the timeline", () => {
  const state = new MonitorState();
  state.setConnection({ connected: true, streaming: true, error: null });
  state.pushEvent({ sessionId: "s1", sequence: 0, type: "turn_start", ts: "2026-08-07T00:00:00Z", turnId: "t1" });
  assert.deepEqual(state.pushEvent({ type: "subscription_replay_truncated", sessionIds: ["s1"] }), []);
  state.noteReplayTruncation({ type: "subscription_replay_truncated", sessionIds: ["s1"] });
  const snapshot = state.snapshot();
  assert.equal(snapshot.streamHealth, "degraded");
  assert.equal(snapshot.streaming, true);
  assert.match(snapshot.error ?? "", /truncated/);
  assert.equal(snapshot.diagnostics.replayTruncations, 1);
  assert.deepEqual(snapshot.events.s1.map((event) => event.kind), ["turn_start"]);
});

test("expired history changes the snapshot tag and yields a pruned body", () => {
  const state = new MonitorState({ historyRetentionMs: 1_000 });
  state.setSessions([{ sessionId: "old", provider: "codex", status: "idle" }]);
  state.pushEvent({ sessionId: "old", sequence: 1, type: "turn_completed", ts: "2026-08-06T23:59:00.000Z", turnId: "t" });
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

test("persisted history survives a monitor restart and old sessions are pruned", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-monitor-db-"));
  try {
    const path = join(directory, "monitor.db");
    const first = await SqliteMonitorStore.open(path, { flushMs: 1 });
    assert.ok(first, "node:sqlite is available");
    const before = new MonitorState({ persistence: first });
    const a = "local:grok:a";
    before.setSessions([{ sessionId: a, provider: "grok", status: "running", updatedAt: new Date().toISOString() }]);
    before.setExternalEvents({ [a]: [localEvent("m1", "2026-08-07T00:00:00Z"), localEvent("m2", "2026-08-07T00:00:01Z")] });
    before.setSessions([]);
    first.close();

    const second = await SqliteMonitorStore.open(path, { flushMs: 1 });
    const after = new MonitorState({ persistence: second });
    assert.equal(after.restoreHistory(), 1);
    const snapshot = after.snapshot();
    assert.deepEqual(snapshot.historySessions.map((session) => session.sessionId), [a]);
    assert.deepEqual(snapshot.historyEvents[a].map((event) => event.key), ["m1", "m2"]);
    // New events continue the restored sequence instead of restarting at 1.
    after.setExternalEvents({ [a]: [localEvent("m3", "2026-08-07T00:00:02Z")] });
    assert.equal(after.eventsFor(a).at(-1).sequence, 3);
    assert.deepEqual(second.readEvents(a, { before: 3, limit: 1 }).map((event) => event.key), ["m2"]);

    assert.equal(second.prune({ retentionDays: 0, keep: new Set() }), 1);
    assert.deepEqual(second.readSessions(), []);
    second.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("persisted history pages newest first, reports its size, and clears on request", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-history-"));
  try {
    const store = await SqliteMonitorStore.open(join(directory, "monitor.db"), { flushMs: 1 });
    for (let index = 0; index < 5; index += 1) {
      store.writeSession({ sessionId: `s${index}`, provider: "codex", updatedAt: new Date(Date.UTC(2026, 8, 26, 0, index)).toISOString() });
    }
    const first = store.readSessions({ limit: 2 });
    assert.deepEqual(first.map((session) => session.sessionId), ["s4", "s3"]);
    const next = store.readSessions({ before: Date.parse(first.at(-1).updatedAt), limit: 2 });
    assert.deepEqual(next.map((session) => session.sessionId), ["s2", "s1"], "paging continues where the last page ended");
    const stats = store.stats();
    assert.equal(stats.sessions, 5);
    assert.ok(stats.bytes > 0);
    assert.equal(store.clear({ keep: new Set(["s4"]) }), 4, "live sessions survive a clear");
    assert.deepEqual(store.readSessions().map((session) => session.sessionId), ["s4"]);
    store.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("the monitor remembers every worker the Gateway reported, across a restart", async () => {
  const state = new MonitorState();
  state.setGatewaySourceSessions([{ sessionId: "acp-1", acpSessionId: "worker-uuid", provider: "claude" }]);
  state.setGatewaySourceSessions([]);
  assert.ok(state.formerWorkerIds.has("worker-uuid"), "a closed Gateway session is still known as a worker");

  const directory = await mkdtemp(join(tmpdir(), "agenlynk-workers-"));
  try {
    const store = await SqliteMonitorStore.open(join(directory, "monitor.db"), { flushMs: 1 });
    store.writeSession({ sessionId: "acp-2", acpSessionId: "worker-2", provider: "codex", updatedAt: new Date().toISOString() });
    store.flush();
    const restarted = new MonitorState({ persistence: store });
    restarted.restoreHistory();
    assert.ok(restarted.formerWorkerIds.has("worker-2"), "restored Gateway history keeps its workers known");
    store.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("history paging does not skip sessions that share a timestamp across pages", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-history-ties-"));
  try {
    const store = await SqliteMonitorStore.open(join(directory, "monitor.db"), { flushMs: 1 });
    const at = new Date(Date.UTC(2026, 8, 26)).toISOString();
    for (const id of ["a", "b", "c", "d"]) store.writeSession({ sessionId: id, provider: "codex", updatedAt: at });
    const first = store.readSessions({ limit: 2 });
    const last = first.at(-1);
    const second = store.readSessions({ before: Date.parse(last.updatedAt), beforeId: last.sessionId, limit: 2 });
    assert.deepEqual([...first, ...second].map((session) => session.sessionId), ["d", "c", "b", "a"]);
    store.close();
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("the worker ledger outlives the monitor and a zero history retention", async () => {
  const { readWorkerLedger, workerLedgerWriter } = await import("../src/store/worker-ledger.js");
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-ledger-"));
  try {
    const path = join(directory, "workers.json");
    const save = workerLedgerWriter(path, 1);
    const first = new MonitorState({ onWorkerRemembered: save });
    first.setGatewaySourceSessions([{ sessionId: "acp-9", acpSessionId: "worker-9" }]);
    save.flush();
    const second = new MonitorState({ formerWorkerIds: readWorkerLedger(path) });
    assert.ok(second.formerWorkerIds.has("worker-9"), "a restarted monitor still knows the worker");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
