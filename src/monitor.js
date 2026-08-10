#!/usr/bin/env node
// Read-only snapshot/SSE sidecar for the native ACP Monitor app.
//
// Connects to the gateway daemon over the same Unix-socket RPC that Main uses
// (reusing Main's identity from install.json), subscribes to all sessions, and
// exposes prompts, worker events, tool calls, permissions, tasks, and inbox
// items to the SwiftUI app over a loopback-only HTTP/SSE API.
//
// The persistent connection uses authenticated observer access and does not
// keep Main's owner-presence lease alive. Explicit user config/restart actions
// use separate short-lived control connections.

import { randomBytes } from "node:crypto";
import { access, mkdir, readFile, rm } from "node:fs/promises";
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { GatewayRpcClient } from "./socket-rpc.js";
import { MONITOR_API_VERSION, MONITOR_SCHEMA_VERSION, MonitorState, queuedSingleFlight } from "./monitor-state.js";
import { gatewaySocketPath } from "./config.js";
import { GATEWAY_BUILD_ID, GATEWAY_RUNTIME_ROOT } from "./version.js";
import { mergeMonitorSessions, projectLocalSnapshot } from "./local-monitor.js";
import { projectCodexTranscript } from "./local-transcript.js";
import { LocalAgentScanner } from "./local-agents/index.js";
import {
  activateRuntimeCandidate,
  inspectRuntime,
  pruneRuntimeVersions,
  rollbackRuntime,
  stageRuntimeCandidate,
  validateRuntimeCandidate
} from "./runtime-updater.js";
import { defaultGatewaySettings, gatewaySettingsSnapshot, updateGatewaySettings } from "./gateway-settings.js";
import {
  installOfficialAgent,
  officialAgentCatalog,
  setOfficialAgentEnabled
} from "./agent-catalog.js";

const MONITOR_HOST = "127.0.0.1";
const MONITOR_PORT = numberEnv("ACP_GATEWAY_MONITOR_PORT", 8642, 0);
const MAX_EVENTS_PER_SESSION = numberEnv("ACP_GATEWAY_MONITOR_MAX_EVENTS", 2000, 1);
const AUTO_START_GATEWAY = booleanEnv("ACP_GATEWAY_MONITOR_AUTOSTART", true);
const EXPECTED_PARENT_PID = optionalPositiveIntegerEnv("ACP_GATEWAY_MONITOR_PARENT_PID");
// Local agent scanning is on unless explicitly disabled; the kill switch
// exists so a scanner fault can never take the Gateway view down with it.
const LOCAL_SCANNER_ENABLED = (process.env.ACP_MONITOR_LOCAL_SCANNER ?? "on") !== "off";
const REFRESH_INTERVAL_MS = 3_000;
const localScanner = LOCAL_SCANNER_ENABLED ? new LocalAgentScanner() : null;

function numberEnv(name, fallback, minimum) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < minimum) throw new Error(`${name} must be a number >= ${minimum}`);
  return value;
}

function booleanEnv(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  if (["1", "true", "on", "yes"].includes(raw.toLowerCase())) return true;
  if (["0", "false", "off", "no"].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} must be on or off`);
}

function optionalPositiveIntegerEnv(name) {
  const raw = process.env[name];
  if (raw == null || raw === "") return null;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`${name} must be a positive integer`);
  return value;
}

// The monitor uses Main's identity to stay inside the same rootId boundary,
// then requests the read-only observer role on the socket.
function loadIdentity() {
  const envToken = process.env.ACP_GATEWAY_CONTROL_TOKEN;
  const envRootId = process.env.ACP_GATEWAY_ROOT_ID;
  const path = process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
  if (envToken && envRootId) return { token: envToken, rootId: envRootId, statePath: path };
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
  return { token: envToken ?? identity.token, rootId: envRootId ?? identity.rootId, statePath: path };
}

async function main() {
  const identity = loadIdentity();
  // A pre-config-API daemon reports most active values through setup, but not
  // every newly introduced setting. Defaults/environment represent what that
  // old process actually booted with; persisted values may only be staged.
  const legacyActiveGatewayValues = defaultGatewaySettings();
  const rpc = new GatewayRpcClient({
    token: identity.token,
    rootId: identity.rootId,
    access: "observer",
    autoStart: AUTO_START_GATEWAY
  });
  const state = new MonitorState({ maxEventsPerSession: MAX_EVENTS_PER_SESSION });
  const apiToken = randomBytes(32).toString("base64url");
  let gatewaySessions = [];
  let subscriptionActive = false;
  let subscriptionAttempt = null;
  let agentMutationActive = false;

  const onEvent = (event) => {
    if (event?.type === "subscription_error") {
      subscriptionActive = false;
      state.connected = false;
      state.streaming = false;
      state.lastError = event.error ?? "Gateway event subscription failed";
      state.broadcast({ kind: "notice", event });
      state.broadcast({ kind: "state", connected: false, streaming: false, error: state.lastError });
      return;
    }
    if (event?.type === "subscription_replay_truncated") {
      state.broadcast({ kind: "notice", event });
      return;
    }
    if (!state.pushEvent(event)) return;
    state.broadcast({ kind: "event", event });
    if (event.type === "session_closed") {
      gatewaySessions = gatewaySessions.filter((session) => session.sessionId !== event.sessionId);
      state.removeSession(event.sessionId, { closed: true });
      state.broadcast({ kind: "session_removed", sessionId: event.sessionId });
    }
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

  async function performRefresh() {
    const wasConnected = state.connected;
    const beforeRevision = state.revision;
    const beforeTasks = JSON.stringify(state.tasks);
    const beforeInbox = JSON.stringify(state.inbox);
    try {
      const [sessions, tasks, inbox] = await Promise.all([
        rpc.call("session", { action: "list" }),
        rpc.call("task_list", {}),
        rpc.call("inbox", { action: "list" })
      ]);
      gatewaySessions = sessions.sessions ?? [];
      const { removedSessionIds } = await applySessionSources();
      state.tasks = tasks.tasks ?? [];
      state.inbox = inbox.items ?? [];
      state.connected = true;
      state.lastError = null;
      const recordsChanged = beforeTasks !== JSON.stringify(state.tasks) || beforeInbox !== JSON.stringify(state.inbox);
      if (state.revision !== beforeRevision || recordsChanged || !wasConnected) {
        state.broadcast({
          kind: "state",
          connected: true,
          streaming: state.streaming,
          sessions: [...state.sessions.values()],
          removedSessionIds,
          tasks: state.tasks,
          inbox: state.inbox
        });
      }
    } catch (error) {
      const { removedSessionIds } = await applySessionSources();
      state.connected = false;
      state.lastError = error?.message ?? String(error);
      state.broadcast({
        kind: "state",
        connected: false,
        streaming: state.streaming,
        error: state.lastError,
        sessions: [...state.sessions.values()],
        removedSessionIds
      });
    }
  }
  const refresh = queuedSingleFlight(performRefresh);

  // Single-flight: this is called from the 1s local interval, the 3s refresh,
  // and event-nudged refreshes. The scanner and transcript reader keep mutable
  // cursors/caches, so two overlapping passes corrupt offsets (both advance the
  // same cursor) and duplicate cached transcript records. Overlapping callers
  // share the in-flight pass; a queued re-run follows for the latecomer.
  const applySessionSources = queuedSingleFlight(async () => {
    const beforeRevision = state.revision;
    const local = await readLocalProjection();
    const merged = mergeMonitorSessions(gatewaySessions, local.sessions);
    const acceptedLocalIds = new Set(merged.filter((session) => session.source === "local").map((session) => session.sessionId));
    const events = Object.fromEntries(Object.entries(local.events).filter(([sessionId]) => acceptedLocalIds.has(sessionId)));
    const removedSessionIds = state.setSessions(merged);
    state.setExternalEvents(events);
    return { removedSessionIds, changed: state.revision !== beforeRevision };
  });

  async function refreshGatewayInfo() {
    try {
      const gateway = annotateRuntimeSplit(await rpc.call("setup", {}), GATEWAY_RUNTIME_ROOT);
      if (state.setGateway(gateway)) state.broadcast({ kind: "gateway", gateway });
    } catch {
      // setup is best-effort metadata; session/event flow works without it.
    }
  }

  async function ensureSubscription() {
    if (subscriptionActive) return;
    if (subscriptionAttempt) return subscriptionAttempt;
    subscriptionAttempt = (async () => {
      try {
        const subscription = await rpc.subscribe({ includeThoughts: true, includeToolEvents: true }, onEvent);
        gatewaySessions = subscription.sessions ?? [];
        await applySessionSources();
        for (const event of subscription.events ?? []) state.pushEvent(event);
        subscriptionActive = true;
        state.connected = true;
        state.streaming = true;
        state.lastError = null;
        state.broadcast({ kind: "state", connected: true, streaming: true });
      } catch (error) {
        subscriptionActive = false;
        state.streaming = false;
        state.lastError = error?.message ?? String(error);
        console.error(`Gateway connection failed: ${state.lastError}`);
      } finally {
        subscriptionAttempt = null;
      }
    })();
    return subscriptionAttempt;
  }

  await ensureSubscription();
  await refreshGatewayInfo();
  await refresh();
  const interval = setInterval(() => {
    void ensureSubscription();
    void refresh();
    void refreshGatewayInfo();
  }, REFRESH_INTERVAL_MS);
  interval.unref();
  const localInterval = setInterval(() => {
    void (async () => {
      const { removedSessionIds, changed } = await applySessionSources();
      if (!changed) return;
      state.broadcast({
        kind: "state",
        connected: state.connected,
        streaming: state.streaming,
        sessions: [...state.sessions.values()],
        removedSessionIds
      });
    })().catch((error) => {
      // Local scanning is a nicety; a fault here must never take the Gateway
      // view down. Without this catch an unhandled rejection kills the process.
      console.error(`Local session refresh failed: ${error.message}`);
    });
  }, 1_000);
  localInterval.unref();

  const server = createServer((request, response) => {
    void handleRequest(request, response).catch((error) => {
      if (response.headersSent) {
        response.end();
        return;
      }
      const statusCode = error?.statusCode ?? 500;
      const code = error?.code ?? (statusCode === 500 ? "monitor_internal" : undefined);
      response.writeHead(statusCode, { "content-type": "application/json; charset=utf-8" });
      response.end(JSON.stringify({ error: error?.message ?? String(error), ...(code ? { code } : {}) }));
    });
  });

  async function handleRequest(request, response) {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    if (request.headers.authorization !== `Bearer ${apiToken}`) {
      response.writeHead(401, { "content-type": "application/json; charset=utf-8" });
      response.end('{"error":"unauthorized","code":"monitor_unauthorized"}');
      return;
    }
    if (url.pathname === "/api/meta" && request.method === "GET") {
      sendJson(response, {
        schemaVersion: MONITOR_SCHEMA_VERSION,
        monitorApiVersion: MONITOR_API_VERSION,
        gatewayIdentity: gatewayIdentity(state, identity),
        capabilities: monitorCapabilities(state)
      });
      return;
    }
    if (url.pathname === "/api/snapshot") {
      response.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store"
      });
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
    if (url.pathname === "/api/agents" && request.method === "GET") {
      sendJson(response, await officialAgentCatalog({ refresh: url.searchParams.get("refresh") === "1" }));
      return;
    }
    if (url.pathname === "/api/agents" && request.method === "POST") {
      if (agentMutationActive) {
        const error = new Error("Another ACP agent operation is already running");
        error.statusCode = 409;
        throw error;
      }
      const body = await readJsonBody(request);
      agentMutationActive = true;
      try {
        const catalog = await officialAgentCatalog();
        if (body.action === "install") {
          const agent = catalog.agents.find((item) => item.registryId === body.registryId);
          if (!agent) throw new Error(`Official ACP agent not found: ${body.registryId ?? "<missing>"}`);
          if (!agent.installSupported) throw new Error(agent.installHint);
          await installOfficialAgent(agent.registryId);
        } else if (body.action === "set_enabled") {
          if (typeof body.enabled !== "boolean") throw new Error("enabled must be boolean");
          const agent = catalog.agents.find((item) => item.providerId === body.providerId);
          if (!agent) throw new Error(`Official ACP provider not found: ${body.providerId ?? "<missing>"}`);
          if (!agent.installed) throw new Error(`${agent.name} is not installed`);
          await setOfficialAgentEnabled(agent.providerId, body.enabled);
        } else {
          throw new Error(`Unknown ACP agent action: ${body.action ?? "<missing>"}`);
        }
        sendJson(response, await officialAgentCatalog());
        void refreshGatewayInfo();
      } finally {
        agentMutationActive = false;
      }
      return;
    }
    if (url.pathname === "/api/session-config" && request.method === "GET") {
      const sessionId = url.searchParams.get("sessionId");
      if (!sessionId) throw new Error("sessionId is required");
      const session = state.sessions.get(sessionId);
      if (session?.status === "disconnected") {
        response.writeHead(200, {
          "content-type": "application/json; charset=utf-8",
          "cache-control": "no-store"
        });
        response.end(JSON.stringify({
          ok: true,
          sessionId,
          configOptions: [],
          unavailableReason: "Worker 연결이 끊긴 세션입니다. 세션을 resume한 뒤 설정을 다시 불러오세요."
        }));
        return;
      }
      let result;
      try {
        result = await rpc.call("config", { action: "list", sessionId });
      } catch (error) {
        // Compatibility with an already-running pre-native-UI daemon that did
        // not yet allow observer config reads. New daemons stay read-only here.
        if (!String(error?.message).includes("Observer access is read-only")) throw error;
        result = await controlCall("config", { action: "list", sessionId });
      }
      response.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store"
      });
      response.end(JSON.stringify(result));
      return;
    }
    if (url.pathname === "/api/session-config" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (typeof body.sessionId !== "string" || !body.sessionId) throw new Error("sessionId is required");
      if (typeof body.configId !== "string" || !body.configId) throw new Error("configId is required");
      if (!(typeof body.value === "string" || typeof body.value === "boolean")) {
        throw new Error("value must be a string or boolean");
      }
      const result = await controlCall("config", {
          action: "set",
          sessionId: body.sessionId,
          configId: body.configId,
          value: body.value
      });
      response.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store"
      });
      response.end(JSON.stringify(result));
      scheduleRefresh();
      return;
    }
    if (url.pathname === "/api/gateway-config" && request.method === "GET") {
      sendJson(response, gatewaySettingsSnapshot({
        statePath: identity.statePath,
        activeValues: activeGatewaySettings(state.gateway, legacyActiveGatewayValues)
      }));
      return;
    }
    if (url.pathname === "/api/gateway-config" && request.method === "POST") {
      const body = await readJsonBody(request);
      const action = body.action ?? "set";
      if (!new Set(["set", "reset"]).has(action)) throw new Error(`Unknown Gateway config action: ${action}`);
      let result;
      try {
        result = await controlCall("gateway_config", action === "set"
          ? { action, values: body.values ?? {} }
          : { action, ids: body.ids ?? [] });
      } catch (error) {
        if (!String(error?.message).includes("Unknown gateway method: gateway_config")) throw error;
        await updateGatewaySettings({
          statePath: identity.statePath,
          values: action === "set" ? body.values ?? {} : {},
          resetIds: action === "reset" ? body.ids ?? [] : []
        });
        result = gatewaySettingsSnapshot({
          statePath: identity.statePath,
          activeValues: activeGatewaySettings(state.gateway, legacyActiveGatewayValues)
        });
      }
      sendJson(response, result);
      return;
    }
    // What a retention change would delete, counted without deleting it. The
    // app asks before saving a value that destroys data.
    if (url.pathname === "/api/retention-preview" && request.method === "POST") {
      const body = await readJsonBody(request);
      const args = {};
      if (Number.isFinite(body.sessionRetentionMs)) args.sessionRetentionMs = body.sessionRetentionMs;
      if (Number.isFinite(body.artifactSessionLimit)) args.artifactSessionLimit = body.artifactSessionLimit;
      sendJson(response, await controlCall("retention_preview", args));
      return;
    }
    // Runtime updater, exposed so the app drives the same operations as
    // runtime-updater-cli.js and receives the library's own JSON envelopes
    // unchanged — one contract, two front ends.
    if (url.pathname === "/api/runtime" && request.method === "GET") {
      sendJson(response, await inspectRuntime({ deep: url.searchParams.get("deep") === "1" }));
      return;
    }
    if (url.pathname.startsWith("/api/runtime/") && request.method === "POST") {
      const operation = url.pathname.slice("/api/runtime/".length);
      const body = await readJsonBody(request);
      // The app never supplies blockers: active work is the monitor's own
      // knowledge, so it cannot be argued away by the caller.
      const blockers = state.restartBlockers();
      const operations = {
        stage: () => stageRuntimeCandidate({ seedRoot: body.seedRoot }),
        validate: () => validateRuntimeCandidate({ versionId: body.versionId }),
        activate: () => activateRuntimeCandidate({ versionId: body.versionId, blockers }),
        rollback: () => rollbackRuntime({ blockers }),
        prune: () => pruneRuntimeVersions({ keep: Array.isArray(body.keep) ? body.keep : [] })
      };
      const run = operations[operation];
      if (!run) {
        const error = new Error(`Unknown runtime operation: ${operation}`);
        error.statusCode = 404;
        error.code = "monitor_not_found";
        throw error;
      }
      const result = await run();
      // The library reports expected failures in the envelope rather than by
      // throwing; keep that shape and let the status code carry the outcome.
      sendJson(response, result, result.ok ? 200 : 409);
      return;
    }
    if (url.pathname === "/api/gateway-restart" && request.method === "POST") {
      const blockers = state.restartBlockers();
      if (blockers.length) throw restartBlockedError(blockers);
      await restartGateway();
      sendJson(response, { ok: true, gateway: state.gateway });
      return;
    }
    response.writeHead(404, { "content-type": "application/json" });
    response.end('{"error":"not found","code":"monitor_not_found"}');
  }

  async function controlCall(method, args) {
    const control = new GatewayRpcClient({
      token: identity.token,
      rootId: identity.rootId,
      access: "control",
      autoStart: false
    });
    try {
      return await control.call(method, args);
    } finally {
      control.close();
    }
  }

  async function restartGateway() {
    await controlCall("daemon_shutdown", {});
    const socketPath = gatewaySocketPath();
    for (let attempt = 0; attempt < 100; attempt += 1) {
      const socketGone = await pathIsMissing(socketPath);
      const lockGone = await pathIsMissing(`${socketPath}.lock`);
      if (socketGone && lockGone) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    const starter = new GatewayRpcClient({
      token: identity.token,
      rootId: identity.rootId,
      access: "observer",
      autoStart: true
    });
    try {
      const gateway = await starter.call("setup", {}, 15_000);
      state.setGateway(gateway);
      state.connected = true;
      state.lastError = null;
      state.broadcast({ kind: "gateway", gateway });
    } finally {
      starter.close();
    }
  }

  await new Promise((resolve, reject) => {
    const onError = (error) => reject(error);
    server.once("error", onError);
    server.listen(MONITOR_PORT, MONITOR_HOST, () => {
      server.off("error", onError);
      resolve();
    });
  });
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : MONITOR_PORT;
  console.log(JSON.stringify({
    kind: "monitor_ready",
    schemaVersion: MONITOR_SCHEMA_VERSION,
    monitorApiVersion: MONITOR_API_VERSION,
    url: `http://${MONITOR_HOST}:${port}`,
    apiToken,
    rootId: identity.rootId,
    gatewayIdentity: gatewayIdentity(state, identity),
    capabilities: monitorCapabilities(state)
  }));

  let shuttingDown = false;
  let parentWatch = null;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(interval);
    clearInterval(localInterval);
    if (parentWatch) clearInterval(parentWatch);
    for (const client of state.sseClients) client.end();
    rpc.close();
    await new Promise((resolve) => server.close(resolve));
  };
  if (EXPECTED_PARENT_PID) {
    parentWatch = setInterval(() => {
      if (process.ppid === EXPECTED_PARENT_PID) return;
      void shutdown().finally(() => process.exit(0));
    }, 1_000);
    parentWatch.unref();
  }
  process.on("SIGINT", () => void shutdown().finally(() => process.exit(0)));
  process.on("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
}



async function readLocalProjection() {
  const sessions = await collectLocalSessions();
  if (!sessions.length) return { sessions: [], events: {} };
  try {
    const projection = projectLocalSnapshot({ sessions });
    // Events come from the conversation window the codex tailer already
    // retained during its state pass — the same single read serves both
    // consumers, instead of a second reader re-tailing the same files.
    for (const session of projection.sessions) {
      if (session.provider !== "codex" || !session.localSessionId) continue;
      const records = localScanner.conversationRecords(session.localSessionId);
      if (!records.length) continue;
      const events = projectCodexTranscript(records, {
        sessionId: session.sessionId,
        rawSessionId: session.localSessionId,
        now: Date.now()
      });
      if (events.length) projection.events[session.sessionId] = events;
    }
    return projection;
  } catch (error) {
    console.error(`Local session projection ignored: ${error.message}`);
    return { sessions: [], events: {} };
  }
}

/**
 * Sessions the Gateway never sees. The scanner runs in this process, so there
 * is no snapshot file to read and no Gateway sessions to filter back out — the
 * monitor already holds those over RPC.
 */
async function collectLocalSessions() {
  if (!localScanner) return [];
  try {
    return await localScanner.scan();
  } catch (error) {
    // Local monitoring is a nicety; the Gateway view must survive its failure.
    console.error(`Local agent scan failed: ${error.message}`);
    return [];
  }
}
async function pathIsMissing(path) {
  try {
    await access(path);
    return false;
  } catch (error) {
    if (error?.code === "ENOENT") return true;
    throw error;
  }
}

// Missing Gateway setup values (e.g. before the first successful "setup"
// call) surface as null rather than being omitted, per the shared wire
// contract; apiToken/control token are never part of this shape.
function gatewayIdentity(state, identity) {
  return {
    rootId: identity.rootId ?? null,
    gatewayApiVersion: state.gateway?.gatewayApiVersion ?? null,
    gatewayVersion: state.gateway?.gatewayVersion ?? null,
    gatewayBuildId: state.gateway?.gatewayBuildId ?? null
  };
}

function monitorCapabilities(state) {
  return state.gateway?.capabilities ?? {};
}

// Stable-code contract for a blocked Gateway restart. A pure function of the
// blocker list (produced by MonitorState.restartBlockers) so it's testable
// without a running server: the HTTP handler throws exactly this shape.
/**
 * Marks a setup response whose daemon runs from a different runtime root than
 * this monitor — a split brain. It happens when a dev-checkout daemon holds
 * the socket while the installed runtime's monitor connects (or vice versa):
 * the socket's single-owner race means the stale daemon keeps winning, so the
 * user runs old Gateway code without any visible sign. Detection is the fix's
 * first half; a safe Gateway restart respawns from this monitor's runtime and
 * heals the split.
 */
export function annotateRuntimeSplit(gateway, monitorRuntimeRoot, monitorBuildId = GATEWAY_BUILD_ID) {
  if (!gateway || typeof gateway !== "object") return gateway;
  const daemonRoot = gateway.runtimeRoot;
  if (typeof daemonRoot === "string" && daemonRoot && monitorRuntimeRoot && daemonRoot !== monitorRuntimeRoot) {
    return { ...gateway, runtimeSplit: { daemonRuntimeRoot: daemonRoot, monitorRuntimeRoot } };
  }
  // A healthy pair always runs identical code (the monitor spawns the daemon
  // from its own runtime), so a differing build id is a split even when the
  // root matches or is absent: daemons predating the runtimeRoot field, a dev
  // checkout daemon started before a `git pull`, and the post-update window
  // where current.json already points at the new runtime but the daemon still
  // runs the old one until a restart.
  const daemonBuildId = gateway.gatewayBuildId;
  if (typeof daemonBuildId === "string" && daemonBuildId
    && monitorBuildId && daemonBuildId !== monitorBuildId) {
    return { ...gateway, runtimeSplit: { daemonBuildId, monitorBuildId } };
  }
  return gateway;
}

export function restartBlockedError(blockers) {
  const error = new Error(`Gateway를 안전하게 재시작할 수 없습니다: ${blockers.join(", ")}`);
  error.statusCode = 409;
  error.code = "monitor_restart_blocked";
  return error;
}

function sendJson(response, value, status = 200) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(value));
}

function activeGatewaySettings(gateway, fallback = {}) {
  if (!gateway || typeof gateway !== "object") return fallback;
  const values = {
    ...fallback,
    ...(gateway.lifecycle ?? {}),
    ...(gateway.resourceLimits ?? {})
  };
  if (gateway.agentUpdates?.enabled != null) values.agentAutoUpdate = gateway.agentUpdates.enabled;
  if (gateway.agentUpdates?.notifications != null) values.agentUpdateNotifications = gateway.agentUpdates.notifications;
  if (gateway.agentUpdates?.intervalMs != null) values.agentUpdateIntervalMs = gateway.agentUpdates.intervalMs;
  return Object.fromEntries(Object.entries(values).filter(([, value]) => value != null));
}

async function readJsonBody(request) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > 64 * 1024) throw new Error("request body is too large");
    chunks.push(chunk);
  }
  if (!chunks.length) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new Error("request body must be valid JSON");
  }
}

// Guarded so importing this module for its pure helpers (e.g. in tests)
// never starts the sidecar; only running it directly (`node monitor.js`,
// which is how the Swift app and monitor-control tests spawn it) does.
if (process.argv[1] && process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
