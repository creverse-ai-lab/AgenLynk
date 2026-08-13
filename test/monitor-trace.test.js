import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, readFile, readdir, rm, unlink } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { GatewayService } from "../src/gateway-service.js";
import { MonitorState } from "../src/monitor-state.js";
import { isIgnoredMonitorEvent } from "../src/monitor.js";
import { createSocketSender } from "../src/socket-flow.js";
import { GatewayRpcClient } from "../src/socket-rpc.js";

const traceDirectory = new URL("./fixtures/monitor-traces/", import.meta.url);
const SNAPSHOT_KEYS = [
  "schemaVersion", "monitorApiVersion", "revision", "connected", "streaming",
  "error", "gateway", "sessions", "events", "historySessions", "historyEvents",
  "eventLimit", "tasks", "inbox"
];

test("AgenLynk 1.3.2 setup matches the shared golden contract", async () => {
  const fixture = JSON.parse(await readFile(new URL("./fixtures/gateway-setup-1.3.2.json", import.meta.url), "utf8"));
  const service = new GatewayService({ gcIntervalMs: 0 });
  try {
    await service.init();
    const setup = await service.call("setup", {}, { rootId: "fixture-main" });
    assert.deepEqual(Object.keys(setup).sort(), fixture.keys, "setup top-level keys changed");
    assertSubset(setup, fixture.stable);
    for (const [key, expectedType] of Object.entries(fixture.types)) {
      assert.equal(jsonType(setup[key]), expectedType, `setup.${key} changed type`);
    }
  } finally {
    await service.shutdown();
  }
});

const traceFiles = (await readdir(traceDirectory))
  .filter((name) => name.endsWith(".ndjson"))
  .sort();

for (const file of traceFiles) {
  test(`characterization trace: ${file}`, async () => {
    const trace = await loadTrace(new URL(file, traceDirectory));
    const result = await replayTrace(trace);
    assertGeneratedSnapshot(result.snapshot);
    assert.deepEqual(result.projection, projectSnapshot(result.snapshot), `${trace.meta.name}.generated-projection`);
    assertSubset(result.snapshot, trace.expected.snapshot, `${trace.meta.name}.snapshot`);
    assert.deepEqual(result.projection, normalizedProjection(trace.expected.projection), `${trace.meta.name}.projection`);
    const selected = trace.expected.projection ?? {};
    if (selected.selectedFrontdoorId) {
      assert.ok(
        result.projection.frontdoorIds.includes(selected.selectedFrontdoorId),
        `${trace.meta.name}: selected Frontdoor missing from generated projection`
      );
    }
    if (selected.selectedEventRef) {
      assert.ok(
        result.projection.eventRefs.includes(selected.selectedEventRef),
        `${trace.meta.name}: selected event missing from generated projection`
      );
    }
    if (trace.expected.transport) {
      assertSubset(result.transport, trace.expected.transport, `${trace.meta.name}.transport`);
    }
    if (trace.expected.meta) {
      assertSubset(result.meta, trace.expected.meta, `${trace.meta.name}.meta`);
    }
  });
}

async function loadTrace(url) {
  const records = (await readFile(url, "utf8"))
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line, index) => {
      try { return JSON.parse(line); }
      catch (error) { throw new Error(`${url.pathname}:${index + 1}: ${error.message}`); }
    });
  const meta = records[0];
  const expected = records.at(-1);
  assert.equal(meta?.kind, "meta", `${url.pathname} must start with meta`);
  assert.equal(meta.traceVersion, 1, `${url.pathname} uses an unsupported trace version`);
  assert.equal(expected?.kind, "expected", `${url.pathname} must end with expected`);
  return { meta, steps: records.slice(1, -1), expected };
}

async function replayTrace(trace) {
  switch (trace.meta.runner) {
  case "monitor-state": return replayMonitorState(trace);
  case "socket-flow": return replaySocketFlow(trace);
  case "gateway-rpc": return replayGatewayRpc(trace);
  default: throw new Error(`Unknown trace runner: ${trace.meta.runner}`);
  }
}

function replayMonitorState(trace) {
  const state = new MonitorState({
    maxEventsPerSession: Number.isFinite(trace.meta.maxEventsPerSession) ? trace.meta.maxEventsPerSession : 2000
  });
  const sse = [];

  const recordStateSse = (extra = {}) => {
    sse.push({
      kind: "state",
      connected: state.connected,
      streaming: state.streaming,
      ...(state.lastError != null ? { error: state.lastError } : {}),
      sessions: [...state.sessions.values()],
      ...extra
    });
  };

  for (const step of trace.steps) {
    switch (step.kind) {
    case "state":
      if (Object.hasOwn(step, "connected")) state.connected = step.connected;
      if (Object.hasOwn(step, "streaming")) state.streaming = step.streaming;
      if (Object.hasOwn(step, "error")) state.lastError = step.error;
      if (Object.hasOwn(step, "sessions")) {
        const removedSessionIds = state.setSessions(step.sessions);
        recordStateSse({ removedSessionIds });
      }
      break;
    case "set_gateway": state.setGateway(step.gateway); break;
    case "set_sessions": state.setSessions(step.sessions); break;
    case "push_event":
      if (!isIgnoredMonitorEvent(step.event)) state.pushEvent(step.event);
      break;
    case "set_tasks": state.tasks = step.tasks; break;
    case "set_inbox": state.inbox = step.inbox; break;
    case "checkpoint": {
      const snapshot = state.snapshot();
      assertSubset(snapshot, step.snapshot, `${trace.meta.name}.checkpoint`);
      if (step.meta) {
        assertSubset(derivedMonitorMeta(state, trace.meta.rootId), step.meta, `${trace.meta.name}.checkpoint.meta`);
      }
      if (step.sse) {
        assert.ok(sse.length, `${trace.meta.name}.checkpoint.sse is missing`);
        assertSubset(sse.at(-1), step.sse, `${trace.meta.name}.checkpoint.sse`);
      }
      break;
    }
    default: throw new Error(`Unknown monitor-state step: ${step.kind}`);
    }
  }
  const snapshot = state.snapshot();
  return {
    snapshot,
    projection: projectSnapshot(snapshot),
    transport: sse.length ? { sse } : undefined,
    meta: derivedMonitorMeta(state, trace.meta.rootId)
  };
}

function replaySocketFlow(trace) {
  const input = trace.steps.find((step) => step.kind === "socket_flow");
  assert.ok(input, "socket-flow trace requires socket_flow input");
  const writes = [];
  const removed = [];
  const socket = {
    destroyed: false,
    writableLength: input.writableLength,
    write(value) { writes.push(JSON.parse(value)); },
    destroy() { this.destroyed = true; }
  };
  const sender = createSocketSender(socket, {
    unsubscribe: (id) => removed.push(`service:${id}`),
    removeSubscription: (id) => removed.push(`socket:${id}`),
    maxSubscriptionBytes: input.maxSubscriptionBytes,
    maxConnectionBytes: input.maxConnectionBytes
  });
  const delivered = sender.sendEvent(input.subscriptionId, input.event);
  sender.send({ id: "control", ok: true });

  const subscriptionError = writes.find((message) => message.type === "subscription_error") ?? null;
  const state = new MonitorState();
  state.connected = true;
  // monitor.js onEvent(subscription_error): pause streaming, keep connected,
  // broadcast kind:"state". No kind:"notice" is written.
  if (!delivered && subscriptionError) {
    state.streaming = false;
    state.lastError = subscriptionError.error ?? "Gateway event subscription failed";
  } else {
    state.streaming = delivered;
    state.lastError = delivered ? null : writes[0]?.error ?? null;
  }
  const snapshot = state.snapshot();
  return {
    snapshot,
    projection: projectSnapshot(snapshot),
    meta: derivedMonitorMeta(state, trace.meta.rootId),
    transport: {
      delivered,
      socketDestroyed: socket.destroyed,
      removed,
      writeTypes: writes.map((message) => message.type ?? message.id),
      subscriptionError: subscriptionError
        ? { type: subscriptionError.type, error: subscriptionError.error }
        : null,
      sseState: {
        kind: "state",
        connected: state.connected,
        streaming: state.streaming,
        ...(state.lastError != null ? { error: state.lastError } : {})
      }
    }
  };
}

async function replayGatewayRpc(trace) {
  const initial = trace.steps.find((step) => step.kind === "initial_subscription");
  const restored = trace.steps.find((step) => step.kind === "restored_subscription");
  assert.ok(initial && restored, "gateway-rpc trace requires initial and restored subscriptions");
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-monitor-trace-"));
  const socketPath = join(directory, "gateway.sock");
  const received = [];
  const subscribeArgs = initial.args ?? { includeThoughts: true, includeToolEvents: true };
  let restoredArgs;
  let restoredCursor;
  let first;
  let second;
  const client = new GatewayRpcClient({ socketPath, token: "fixture-token", rootId: "fixture-main", autoStart: false });
  try {
    first = await startSubscriptionServer(socketPath, (request) => ({
      ok: true,
      result: { subscriptionId: initial.subscriptionId, sessions: [], events: [], cursorTruncated: {} },
      event: { subscriptionId: initial.subscriptionId, event: initial.event }
    }));
    const subscription = await client.subscribe(subscribeArgs, (event) => received.push(event));
    await waitFor(() => received.some((event) => event.sequence === initial.event.sequence));

    for (const socket of first.sockets) socket.destroy();
    first.server.close();
    await once(first.server, "close");
    await unlink(socketPath).catch(() => {});

    second = await startSubscriptionServer(socketPath, (request) => {
      if (request.method === "subscribe") {
        restoredArgs = request.args;
        restoredCursor = request.args.cursors?.[initial.event.sessionId];
        return {
          ok: true,
          result: {
            subscriptionId: restored.subscriptionId,
            sessions: [],
            events: restored.replay,
            cursorTruncated: restored.cursorTruncated
          },
          event: { subscriptionId: restored.subscriptionId, event: restored.event }
        };
      }
      return { ok: true, result: { removed: true } };
    });
    await waitFor(() => received.some((event) => event.sequence === restored.event.sequence));
    await client.unsubscribe(subscription.subscriptionId);

    const state = new MonitorState();
    state.connected = true;
    state.streaming = true;
    for (const event of received) {
      if (event?.type === "subscription_replay_truncated") continue;
      if (event?.type === "subscription_error") {
        state.streaming = false;
        state.lastError = event.error ?? "Gateway event subscription failed";
        continue;
      }
      if (isIgnoredMonitorEvent(event)) continue;
      if (Number.isFinite(event.sequence)) state.pushEvent(event);
    }
    const snapshot = state.snapshot();
    return {
      snapshot,
      projection: projectSnapshot(snapshot),
      meta: derivedMonitorMeta(state, trace.meta.rootId),
      transport: {
        subscribeArgs: restoredArgs,
        restoredCursor,
        sequences: received.filter((event) => Number.isFinite(event.sequence)).map((event) => event.sequence),
        receivedTypes: received.map((event) => event.type),
        cursorTruncated: restored.cursorTruncated,
        replayTruncated: received
          .filter((event) => event.type === "subscription_replay_truncated")
          .map((event) => event.sessionIds)
      }
    };
  } finally {
    client.close();
    for (const fixture of [first, second]) {
      if (!fixture) continue;
      for (const socket of fixture.sockets) socket.destroy();
      if (fixture.server.listening) {
        fixture.server.close();
        await once(fixture.server, "close");
      }
    }
    await rm(directory, { recursive: true, force: true });
  }
}

function projectSnapshot(snapshot) {
  const sessions = [...snapshot.historySessions, ...snapshot.sessions];
  const frontdoorIds = [...new Set(sessions.map((session) => session.openerInstanceId).filter(Boolean))].sort();
  const allEvents = { ...snapshot.historyEvents, ...snapshot.events };
  const eventRefs = Object.values(allEvents).flat().map((event) => `${event.sessionId}:${event.sequence}`).sort();
  return { frontdoorIds, eventRefs };
}

function normalizedProjection(expected = {}) {
  return {
    frontdoorIds: [...(expected.frontdoorIds ?? [])].sort(),
    eventRefs: [...(expected.eventRefs ?? [])].sort()
  };
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
  assert.ok(snapshot && typeof snapshot === "object", "replay must return a complete snapshot");
  for (const key of SNAPSHOT_KEYS) {
    assert.ok(Object.hasOwn(snapshot, key), `generated snapshot missing ${key}`);
  }
}

function assertSubset(actual, expected, path = "value") {
  if (Array.isArray(expected)) {
    assert.ok(Array.isArray(actual), `${path} must be an array`);
    assert.equal(actual.length, expected.length, `${path} length changed`);
    expected.forEach((value, index) => assertSubset(actual[index], value, `${path}[${index}]`));
    return;
  }
  if (expected && typeof expected === "object") {
    assert.ok(actual && typeof actual === "object" && !Array.isArray(actual), `${path} must be an object`);
    for (const [key, value] of Object.entries(expected)) {
      assert.ok(Object.hasOwn(actual, key), `${path}.${key} is missing`);
      assertSubset(actual[key], value, `${path}.${key}`);
    }
    return;
  }
  assert.deepEqual(actual, expected, `${path} changed`);
}

function jsonType(value) {
  if (Array.isArray(value)) return "array";
  if (value === null) return "null";
  return typeof value;
}

async function startSubscriptionServer(socketPath, respond) {
  const sockets = new Set();
  const server = createServer((socket) => {
    sockets.add(socket);
    socket.once("close", () => sockets.delete(socket));
    const lines = createInterface({ input: socket });
    lines.on("line", (line) => {
      const request = JSON.parse(line);
      const response = respond(request);
      const messages = [JSON.stringify({ id: request.id, ...response })];
      if (response.event) messages.push(JSON.stringify({ type: "event", ...response.event }));
      socket.write(`${messages.join("\n")}\n`);
    });
  });
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  return { server, sockets };
}

async function waitFor(predicate) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("Trace condition was not reached");
}
