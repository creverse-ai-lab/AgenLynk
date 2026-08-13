import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";
import { MonitorState } from "../src/projection/monitor-state.js";
import { isIgnoredMonitorEvent } from "../src/server/monitor.js";

const traceDirectory = new URL("./fixtures/monitor-traces/", import.meta.url);
const SNAPSHOT_KEYS = [
  "schemaVersion", "monitorApiVersion", "revision", "connected", "streaming",
  "streamHealth", "diagnostics", "error", "gateway", "sessions", "events", "historySessions", "historyEvents",
  "eventLimit", "tasks", "inbox"
];

const traceFiles = (await readdir(traceDirectory)).filter((name) => name.endsWith(".ndjson")).sort();
for (const file of traceFiles) {
  test(`characterization trace: ${file}`, async () => {
    const trace = await loadTrace(new URL(file, traceDirectory));
    if (trace.meta.runner !== "monitor-state") return;
    const result = replayMonitorState(trace);
    assertGeneratedSnapshot(result.snapshot);
    assert.deepEqual(result.projection, projectSnapshot(result.snapshot));
    assertSubset(result.snapshot, trace.expected.snapshot, `${trace.meta.name}.snapshot`);
    assert.deepEqual(result.projection, normalizedProjection(trace.expected.projection));
    if (trace.expected.meta) assertSubset(result.meta, trace.expected.meta, `${trace.meta.name}.meta`);
  });
}

async function loadTrace(url) {
  const records = (await readFile(url, "utf8")).split(/\r?\n/).filter(Boolean).map(JSON.parse);
  const meta = records[0];
  const expected = records.at(-1);
  assert.equal(meta?.kind, "meta");
  assert.equal(meta.traceVersion, 1);
  assert.equal(expected?.kind, "expected");
  return { meta, steps: records.slice(1, -1), expected };
}

function replayMonitorState(trace) {
  const state = new MonitorState({ maxEventsPerSession: trace.meta.maxEventsPerSession ?? 2000 });
  for (const step of trace.steps) {
    switch (step.kind) {
    case "state":
      state.setConnection({
        connected: Object.hasOwn(step, "connected") ? step.connected : state.connected,
        streaming: Object.hasOwn(step, "streaming") ? step.streaming : state.streaming,
        error: Object.hasOwn(step, "error") ? step.error : state.lastError
      });
      if (Object.hasOwn(step, "sessions")) state.setSessions(step.sessions);
      break;
    case "set_gateway": state.setGateway(step.gateway); break;
    case "set_sessions": state.setSessions(step.sessions); break;
    case "push_event": if (!isIgnoredMonitorEvent(step.event)) state.pushEvent(step.event); break;
    case "set_tasks": state.setRecords({ tasks: step.tasks }); break;
    case "set_inbox": state.setRecords({ inbox: step.inbox }); break;
    case "subscription_gap": state.beginSubscriptionGap(step.event); break;
    case "replay_event": state.pushEvent(step.event, { replay: true }); break;
    case "reconciled": state.completeReconciliation(); break;
    case "checkpoint": assertSubset(state.snapshot(), step.snapshot, `${trace.meta.name}.checkpoint`); break;
    default: throw new Error(`Unknown monitor-state step: ${step.kind}`);
    }
  }
  const snapshot = state.snapshot();
  return { snapshot, projection: projectSnapshot(snapshot), meta: derivedMonitorMeta(state, trace.meta.rootId) };
}

function projectSnapshot(snapshot) {
  const sessions = [...snapshot.historySessions, ...snapshot.sessions];
  const frontdoorIds = [...new Set(sessions.map((session) => session.openerInstanceId).filter(Boolean))].sort();
  const allEvents = { ...snapshot.historyEvents, ...snapshot.events };
  const eventRefs = Object.values(allEvents).flat().map((event) => `${event.sessionId}:${event.sequence}`).sort();
  return { frontdoorIds, eventRefs };
}

function normalizedProjection(expected = {}) {
  return { frontdoorIds: [...(expected.frontdoorIds ?? [])].sort(), eventRefs: [...(expected.eventRefs ?? [])].sort() };
}

function derivedMonitorMeta(state, rootId = null) {
  return {
    schemaVersion: 1,
    monitorApiVersion: "1.0",
    gatewayIdentity: {
      rootId: rootId ?? null,
      gatewayApiVersion: state.gateway?.gatewayApiVersion ?? null,
      gatewayVersion: state.gateway?.gatewayVersion ?? null,
      gatewayBuildId: state.gateway?.gatewayBuildId ?? null
    },
    capabilities: state.gateway?.capabilities ?? {}
  };
}

function assertGeneratedSnapshot(snapshot) {
  for (const key of SNAPSHOT_KEYS) assert.ok(Object.hasOwn(snapshot, key), `generated snapshot missing ${key}`);
}

function assertSubset(actual, expected, path = "value") {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${path} must be an array`);
    assert.equal(actual.length, expected.length, `${path} length changed`);
    expected.forEach((value, index) => assertSubset(actual[index], value, `${path}[${index}]`));
  } else if (expected && typeof expected === "object") {
    assert.ok(actual && typeof actual === "object" && !Array.isArray(actual), `${path} must be an object`);
    for (const [key, value] of Object.entries(expected)) {
      assert.ok(Object.hasOwn(actual, key), `${path}.${key} is missing`);
      assertSubset(actual[key], value, `${path}.${key}`);
    }
  } else assert.deepEqual(actual, expected, `${path} changed`);
}
