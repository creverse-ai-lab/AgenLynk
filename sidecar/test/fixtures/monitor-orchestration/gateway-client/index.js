// Deterministic Gateway 1.4.0 public-client stand-in for the live sidecar test.
// Shapes match the official subscribe callback/result contract. Do not import
// the pinned runtime from here.

import { createServer } from "node:http";
import { writeFileSync } from "node:fs";

export const GATEWAY_API_VERSION = 1;
export const ERROR_CODES = Object.freeze({
  CONTROL_ACCESS_DENIED: "CONTROL_ACCESS_DENIED",
  UNKNOWN_METHOD: "UNKNOWN_METHOD"
});

export class GatewayError extends Error {
  constructor(code, message) {
    super(message);
    this.code = code;
  }
}

const SESSION = {
  sessionId: "s-live",
  provider: "grok",
  status: "running",
  cwd: "/tmp/project"
};

const subscriptions = new Map();
const subscribeCalls = [];
const unsubscribed = [];
let subscribeSeq = 0;
let hold = null;
let candidateHeld = false;

function publicSetup() {
  return {
    ok: true,
    gatewayVersion: "1.4.0",
    gatewayApiVersion: 1,
    stateSchemaVersion: 5,
    responseProfiles: ["current", "compact", "diagnostic"],
    persistence: { healthy: true, error: null },
    lifecycle: {},
    resourceLimits: {},
    metrics: {},
    alerts: [],
    detected: [],
    providers: []
  };
}

function isRewind(args) {
  return Object.keys(args?.cursors ?? {}).length > 0;
}

function waitForRelease() {
  return new Promise((resolve, reject) => {
    hold = { resolve, reject };
  });
}

export class GatewayRpcClient {
  constructor(options = {}) {
    this.options = options;
    this.closed = false;
  }

  async call(method, args = {}) {
    if (method === "setup") return publicSetup();
    if (method === "session" && args.action === "list") return { sessions: [SESSION] };
    if (method === "task_list") return { tasks: [] };
    if (method === "inbox") return { items: [] };
    throw new GatewayError(ERROR_CODES.UNKNOWN_METHOD, `unknown method ${method}`);
  }

  async subscribe(args = {}, onEvent) {
    if (typeof onEvent !== "function") throw new Error("Subscription event handler is required");
    const subscribeArgs = { ...args, acceptsGaps: true };
    subscribeSeq += 1;
    const subscriptionId = `sub-${subscribeSeq}`;
    const record = { subscriptionId, onEvent, args: subscribeArgs, active: true };
    subscriptions.set(subscriptionId, record);
    subscribeCalls.push({
      subscriptionId,
      cursors: { ...(args.cursors ?? {}) },
      includeThoughts: subscribeArgs.includeThoughts === true,
      includeToolEvents: subscribeArgs.includeToolEvents === true,
      acceptsGaps: subscribeArgs.acceptsGaps === true
    });

    if (isRewind(args)) {
      candidateHeld = true;
      try {
        await waitForRelease();
      } finally {
        candidateHeld = false;
      }
      return {
        subscriptionId,
        sessions: [SESSION],
        events: [
          { sessionId: SESSION.sessionId, sequence: 1, type: "agent_message_chunk", ts: "2026-08-13T00:00:01.000Z", text: "one" },
          { sessionId: SESSION.sessionId, sequence: 2, type: "agent_message_chunk", ts: "2026-08-13T00:00:02.000Z", text: "two" }
        ],
        cursorTruncated: { [SESSION.sessionId]: false }
      };
    }

    return {
      subscriptionId,
      sessions: [SESSION],
      events: [
        { sessionId: SESSION.sessionId, sequence: 0, type: "turn_start", ts: "2026-08-13T00:00:00.000Z" },
        { sessionId: SESSION.sessionId, sequence: 3, type: "agent_message_chunk", ts: "2026-08-13T00:00:03.000Z", text: "after" }
      ],
      cursorTruncated: { [SESSION.sessionId]: false }
    };
  }

  async unsubscribe(subscriptionId) {
    const record = subscriptions.get(subscriptionId);
    if (record) record.active = false;
    unsubscribed.push(subscriptionId);
    return { ok: true, removed: Boolean(record) };
  }

  close() {
    this.closed = true;
  }
}

function sendJson(response, value, status = 200) {
  response.writeHead(status, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify(value));
}

async function readJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  if (!chunks.length) return {};
  return JSON.parse(Buffer.concat(chunks).toString("utf8"));
}

function statusBody() {
  return {
    subscribeCalls,
    active: [...subscriptions.values()].filter((item) => item.active).map((item) => item.subscriptionId),
    unsubscribed: [...unsubscribed],
    candidateHeld
  };
}

function emitOn(subscriptionId, event) {
  const record = subscriptionId
    ? subscriptions.get(subscriptionId)
    : [...subscriptions.values()].find((item) => item.active);
  if (!record?.active) throw new Error("no active subscription to emit on");
  const payload = event.type === "subscription_gap"
    ? { ...event, subscriptionId: record.subscriptionId }
    : event;
  record.onEvent(payload);
  return { ok: true, subscriptionId: record.subscriptionId };
}

const controlFile = process.env.ACP_GATEWAY_TEST_CONTROL_FILE;
if (controlFile) {
  const server = createServer((request, response) => {
    void (async () => {
      const url = new URL(request.url, "http://127.0.0.1");
      if (request.method === "GET" && url.pathname === "/status") {
        sendJson(response, statusBody());
        return;
      }
      if (request.method === "POST" && url.pathname === "/emit") {
        const body = await readJson(request);
        sendJson(response, emitOn(body.subscriptionId, body.event));
        return;
      }
      if (request.method === "POST" && url.pathname === "/release-candidate") {
        hold?.resolve();
        hold = null;
        sendJson(response, { ok: true });
        return;
      }
      sendJson(response, { error: "not found" }, 404);
    })().catch((error) => {
      sendJson(response, { error: error.message }, 500);
    });
  });
  await new Promise((resolve) => {
    server.listen(0, "127.0.0.1", resolve);
  });
  server.unref();
  const address = server.address();
  writeFileSync(controlFile, JSON.stringify({
    url: `http://127.0.0.1:${address.port}`
  }));
}
