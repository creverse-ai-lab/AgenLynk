#!/usr/bin/env node
// Read-only pipeline monitor GUI for the ACP Gateway.
//
// Connects to the gateway daemon over the same Unix-socket RPC that Main uses
// (reusing Main's identity from install.json), subscribes to all sessions, and
// serves a local dashboard that shows prompts, worker events, tool calls,
// permissions, tasks, and inbox items as they flow through the gateway.
//
// Note: holding this connection counts as owner presence for Main's rootId, so
// unpinned sessions will not start their orphan-cancel clock while the monitor
// is running.

import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { GatewayRpcClient } from "./socket-rpc.js";

const MONITOR_HOST = "127.0.0.1";
const MONITOR_PORT = numberEnv("ACP_GATEWAY_MONITOR_PORT", 8642);
const MAX_EVENTS_PER_SESSION = numberEnv("ACP_GATEWAY_MONITOR_MAX_EVENTS", 2000);
const REFRESH_INTERVAL_MS = 3_000;

const uiPath = join(dirname(fileURLToPath(import.meta.url)), "monitor-ui.html");

function numberEnv(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value <= 0) throw new Error(`${name} must be a positive number`);
  return value;
}

// The monitor authenticates as Main itself: the gateway scopes every read to
// one rootId, so observing Main's sessions requires Main's exact identity.
function loadIdentity() {
  const envToken = process.env.ACP_GATEWAY_CONTROL_TOKEN;
  const envRootId = process.env.ACP_GATEWAY_ROOT_ID;
  if (envToken && envRootId) return { token: envToken, rootId: envRootId };
  const path = process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
  let state;
  try {
    state = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Cannot read gateway identity from ${path}: ${error.message}. Run the installer first or set ACP_GATEWAY_CONTROL_TOKEN and ACP_GATEWAY_ROOT_ID.`);
  }
  const identity = state?.identity;
  if (!identity?.token || !identity?.rootId) {
    throw new Error(`No identity in ${path}; run acp-gateway-bootstrap or set ACP_GATEWAY_CONTROL_TOKEN and ACP_GATEWAY_ROOT_ID.`);
  }
  return { token: envToken ?? identity.token, rootId: envRootId ?? identity.rootId };
}

class MonitorState {
  constructor() {
    this.sessions = new Map();
    this.eventsBySession = new Map();
    this.tasks = [];
    this.inbox = [];
    this.gateway = null;
    this.connected = false;
    this.lastError = null;
    this.sseClients = new Set();
  }

  setSessions(list) {
    this.sessions = new Map(list.map((session) => [session.sessionId, session]));
  }

  pushEvent(event) {
    if (!event?.sessionId) return;
    const events = this.eventsBySession.get(event.sessionId) ?? [];
    events.push(event);
    if (events.length > MAX_EVENTS_PER_SESSION) events.splice(0, events.length - MAX_EVENTS_PER_SESSION);
    this.eventsBySession.set(event.sessionId, events);
  }

  snapshot() {
    return {
      connected: this.connected,
      error: this.lastError,
      gateway: this.gateway,
      sessions: [...this.sessions.values()],
      events: Object.fromEntries(this.eventsBySession),
      tasks: this.tasks,
      inbox: this.inbox
    };
  }

  broadcast(message) {
    const frame = `data: ${JSON.stringify(message)}\n\n`;
    for (const client of this.sseClients) {
      client.write(frame, (error) => {
        if (error) this.sseClients.delete(client);
      });
    }
  }
}

async function main() {
  const identity = loadIdentity();
  const rpc = new GatewayRpcClient({ token: identity.token, rootId: identity.rootId });
  const state = new MonitorState();

  const onEvent = (event) => {
    if (event?.type === "subscription_error" || event?.type === "subscription_replay_truncated") {
      state.broadcast({ kind: "notice", event });
      return;
    }
    state.pushEvent(event);
    state.broadcast({ kind: "event", event });
    // Session status flips (running/idle/waiting_*) live on the session record,
    // so nudge a refresh whenever a lifecycle event lands.
    if (!event.type?.endsWith("_chunk")) scheduleRefresh();
  };

  let refreshTimer = null;
  const scheduleRefresh = () => {
    if (refreshTimer) return;
    refreshTimer = setTimeout(() => {
      refreshTimer = null;
      void refresh();
    }, 250);
  };

  async function refresh() {
    try {
      const [sessions, tasks, inbox] = await Promise.all([
        rpc.call("session", { action: "list" }),
        rpc.call("task_list", {}),
        rpc.call("inbox", { action: "list" })
      ]);
      const before = JSON.stringify([state.snapshot().sessions, state.tasks, state.inbox]);
      state.setSessions(sessions.sessions ?? []);
      state.tasks = tasks.tasks ?? [];
      state.inbox = inbox.items ?? [];
      state.connected = true;
      state.lastError = null;
      const after = JSON.stringify([[...state.sessions.values()], state.tasks, state.inbox]);
      if (before !== after) {
        state.broadcast({ kind: "state", sessions: [...state.sessions.values()], tasks: state.tasks, inbox: state.inbox });
      }
    } catch (error) {
      state.connected = false;
      state.lastError = error?.message ?? String(error);
      state.broadcast({ kind: "state", connected: false, error: state.lastError });
    }
  }

  async function refreshGatewayInfo() {
    try {
      state.gateway = await rpc.call("setup", {});
    } catch {
      // setup is best-effort metadata; session/event flow works without it.
    }
  }

  try {
    const subscription = await rpc.subscribe({ includeThoughts: true, includeToolEvents: true }, onEvent);
    state.setSessions(subscription.sessions ?? []);
    for (const event of subscription.events ?? []) state.pushEvent(event);
    state.connected = true;
  } catch (error) {
    state.lastError = error?.message ?? String(error);
    console.error(`Gateway connection failed: ${state.lastError}`);
  }
  await refreshGatewayInfo();
  await refresh();
  const interval = setInterval(() => {
    void refresh();
    void refreshGatewayInfo();
  }, REFRESH_INTERVAL_MS);
  interval.unref();

  const server = createServer((request, response) => {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    if (url.pathname === "/" || url.pathname === "/live") {
      response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
      response.end(readFileSync(uiPath));
      return;
    }
    if (url.pathname === "/api/snapshot") {
      response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
      response.end(JSON.stringify(state.snapshot()));
      return;
    }
    if (url.pathname === "/api/stream") {
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive"
      });
      response.write("retry: 2000\n\n");
      state.sseClients.add(response);
      request.on("close", () => state.sseClients.delete(response));
      return;
    }
    response.writeHead(404, { "content-type": "application/json" });
    response.end('{"error":"not found"}');
  });

  server.listen(MONITOR_PORT, MONITOR_HOST, () => {
    console.log(`ACP Gateway monitor: http://${MONITOR_HOST}:${MONITOR_PORT} (rootId ${identity.rootId})`);
  });

  const shutdown = () => {
    clearInterval(interval);
    for (const client of state.sseClients) client.end();
    server.close();
    rpc.close();
    process.exit(0);
  };
  process.on("SIGINT", shutdown);
  process.on("SIGTERM", shutdown);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
