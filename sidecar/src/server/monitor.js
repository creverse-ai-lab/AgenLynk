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
import { mkdir, readFile, rm } from "node:fs/promises";
import { readFileSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { GatewayRpcClient } from "../gateway/client.js";
import {
  decodeGatewaySetup,
  gatewayFeatureAvailable,
  isGatewayError,
  unavailableFeatureError
} from "../gateway/compatibility.js";
import { GatewaySubscriptionOwner } from "../gateway/subscription-reconciler.js";
import { pathIsMissing } from "../app/fs-paths.js";
import { gatewaySocketPath } from "../app/config.js";
import { defaultInstallStatePath } from "../app/install-state.js";
import {
  GATEWAY_SETTING_DEFINITIONS,
  defaultGatewaySettings,
  gatewaySettingsSnapshot,
  resolveGatewaySettings,
  updateGatewaySettings
} from "../app/gateway-settings.js";
import { installOfficialAgent, officialAgentCatalog, setOfficialAgentEnabled } from "../app/agent-catalog.js";
import { MONITOR_API_VERSION, MONITOR_SCHEMA_VERSION, MonitorState, queuedSingleFlight } from "../projection/monitor-state.js";
import { SIDECAR_BUILD_ID, SIDECAR_VERSION } from "../version.js";
import { mergeMonitorSessions, projectLocalSnapshot } from "../local-monitor.js";
import { LocalAgentScanner } from "../local-agents/index.js";
import { LocalTimeline } from "../normalize/local-timeline.js";
import { SqliteMonitorStore, defaultMonitorDatabasePath } from "../store/sqlite-store.js";
import { HookSessions } from "../hooks/registry.js";
import { defaultWorkerLedgerPath, readWorkerLedger, workerLedgerWriter } from "../store/worker-ledger.js";
import { defaultHookEndpointPath, newHookToken, removeHookEndpoint, writeHookEndpoint } from "../hooks/endpoint.js";
import { HOOK_PROVIDERS as INSTALLABLE_HOOK_PROVIDERS, ensureHooks, hookStatus, installHooks, uninstallHooks } from "../hooks/installer.js";
/*
 * Gateway code above comes only from the release artifact's public client.
 */

const MONITOR_HOST = "127.0.0.1";
const MONITOR_PORT = numberEnv("ACP_GATEWAY_MONITOR_PORT", 8642, 0);
const MAX_EVENTS_PER_SESSION = numberEnv("ACP_GATEWAY_MONITOR_MAX_EVENTS", 2000, 1);
const AUTO_START_GATEWAY = booleanEnv("ACP_GATEWAY_MONITOR_AUTOSTART", true);
const EXPECTED_PARENT_PID = optionalPositiveIntegerEnv("ACP_GATEWAY_MONITOR_PARENT_PID");
const REFRESH_INTERVAL_MS = 3_000;
// Streamed Gateway chunks are coalesced into one SSE frame per window so a
// growing message is re-sent at most this often, not once per token.
const EVENT_BROADCAST_MS = 100;
const HISTORY_PRUNE_INTERVAL_MS = 60 * 60 * 1000;
const HISTORY_ENABLED = booleanEnv("ACP_GATEWAY_MONITOR_HISTORY", true);
// Off unless the app turns it on: a sidecar started by tests or by hand must
// never take over the app's hook endpoint or edit the user's agent configs.
const HOOKS_ENABLED = booleanEnv("ACP_GATEWAY_MONITOR_HOOKS", false);
const MAX_HOOK_BODY_BYTES = 1024 * 1024;
const HOOK_PROVIDERS = new Set(["claude", "codex", "grok"]);
const GATEWAY_RUNTIME_ROOT = process.env.ACP_GATEWAY_ACTIVE_ROOT ?? null;
const EXPECTED_GATEWAY_BUILD_ID = expectedGatewayBuildId(GATEWAY_RUNTIME_ROOT);
// Initialized inside main() so corrupt settings are reported through its
// guarded startup path instead of throwing while this module is imported.
let localScanner = null;
let localTimeline = null;
// Live facts from agent hooks, overlaid on every local scan. Replaced in
// main() once the retention setting is known.
let hookSessions = new HookSessions();

// Token accounting is not timeline content, and a session accumulates one of
// these per turn. Gateway 1.3.2+ already drops them at ingestion, but a
// long-lived pre-1.3.2 daemon replays hundreds from its persisted sessions on
// every subscribe — the monitor cannot assume the daemon it connects to runs
// its own build, so it drops them again here.
const IGNORED_EVENT_TYPES = new Set(["usage_update", "subscription_gap", "subscription_replay_truncated"]);

export function isIgnoredMonitorEvent(event) {
  return IGNORED_EVENT_TYPES.has(event?.type);
}

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
  // Keep the scanner's cost policy with the rest of the user-editable Gateway
  // settings. The sidecar is restarted after changing these options, so one
  // immutable scanner instance owns its cursors and watcher for its lifetime.
  const monitorSettings = resolveGatewaySettings();
  const localScanIntervalMs = monitorSettings.localScanIntervalMs;
  localScanner = monitorSettings.localScannerEnabled ? new LocalAgentScanner({
    discoveryIntervalSeconds: monitorSettings.localDiscoveryIntervalMs / 1_000,
    conversationWindowMs: monitorSettings.localTranscriptWindowMs,
    maxConversationRecords: monitorSettings.localTranscriptRecordLimit,
    readyAfter: monitorSettings.localSessionRetentionMs / 1_000
  }) : null;
  // One retention rule for every provider, whether hooks are on or not.
  hookSessions = new HookSessions({ staleAfterMs: monitorSettings.localSessionRetentionMs });
  localTimeline = localScanner
    ? new LocalTimeline({ codexRecords: (sessionId) => localScanner.conversationRecords(sessionId) })
    : null;
  // A pre-config-API daemon reports most active values through setup, but not
  // every newly introduced setting. Defaults/environment represent what that
  // old process actually booted with; persisted values may only be staged.
  const legacyActiveGatewayValues = defaultGatewaySettings();
  // What this process booted with. The monitor group is the sidecar's own and
  // takes effect only at its start, so these are its active values; Worker
  // settings are passed to a Gateway started with the same snapshot, which
  // is the best record of them when the Gateway does not report its own.
  const bootValues = (group) => Object.fromEntries(GATEWAY_SETTING_DEFINITIONS
    .filter((definition) => definition.group === group)
    .map((definition) => [definition.id, monitorSettings[definition.id]]));
  const bootMonitorValues = bootValues("monitor");
  const bootFallbackValues = { ...legacyActiveGatewayValues, ...bootValues("workers") };
  const activeConfigValues = () => ({
    ...activeGatewaySettings(state.gateway, bootFallbackValues),
    ...bootMonitorValues
  });
  const rpc = new GatewayRpcClient({
    token: identity.token,
    rootId: identity.rootId,
    access: "observer",
    autoStart: AUTO_START_GATEWAY
  });
  const historyRetentionMs = monitorSettings.monitorHistoryRetentionMs;
  const persistence = HISTORY_ENABLED && historyRetentionMs > 0
    ? await SqliteMonitorStore.open(defaultMonitorDatabasePath(), { retentionDays: historyRetentionMs / 86_400_000 })
    : null;
  // Stats when no store is open: retention 0 (or history disabled) may still
  // leave a monitor.db from before, which the app offers to delete.
  const diskHistoryWithoutStore = () => {
    const path = defaultMonitorDatabasePath();
    const file = diskHistoryFileBytes(path);
    return {
      available: false,
      retentionDays: historyRetentionMs / 86_400_000,
      ...(file.exists ? { path, bytes: file.bytes, fileExists: true } : { fileExists: false })
    };
  };
  // A session that leaves the live list stays in the in-memory log as long as
  // an idle one stays live, so every provider disappears on the same clock;
  // older history is browsed from the database.
  const workerLedgerPath = defaultWorkerLedgerPath();
  const saveWorkerLedger = HISTORY_ENABLED ? workerLedgerWriter(workerLedgerPath) : null;
  const state = new MonitorState({
    maxEventsPerSession: MAX_EVENTS_PER_SESSION,
    persistence,
    historyRetentionMs: monitorSettings.localSessionRetentionMs,
    formerWorkerIds: HISTORY_ENABLED ? readWorkerLedger(workerLedgerPath) : [],
    onWorkerRemembered: saveWorkerLedger
  });
  state.restoreHistory();
  persistence?.prune();
  const historyPrune = setInterval(() => {
    persistence?.prune({ keep: new Set(state.sessions.keys()) });
  }, HISTORY_PRUNE_INTERVAL_MS);
  historyPrune.unref();

  // Changed canonical events waiting for the next coalesced `events` frame.
  let pendingEvents = new Map();
  let eventFlushTimer = null;
  const queueEvents = (sessionId, events) => {
    if (!events.length) return;
    let bucket = pendingEvents.get(sessionId);
    if (!bucket) {
      bucket = new Map();
      pendingEvents.set(sessionId, bucket);
    }
    for (const event of events) bucket.set(event.id, event);
    if (eventFlushTimer) return;
    eventFlushTimer = setTimeout(flushEvents, EVENT_BROADCAST_MS);
    eventFlushTimer.unref?.();
  };
  const flushEvents = () => {
    eventFlushTimer = null;
    if (!pendingEvents.size) return;
    const events = Object.fromEntries([...pendingEvents].map(([sessionId, bucket]) => [sessionId, [...bucket.values()]]));
    pendingEvents = new Map();
    state.broadcast({ kind: "events", events });
  };
  const apiToken = randomBytes(32).toString("base64url");
  // Hooks authenticate with their own token: the API token never leaves the
  // app process, while this one is written to a 0600 file for hook scripts.
  const hookToken = newHookToken();
  const hookEndpointPath = defaultHookEndpointPath();
  let agentMutationActive = false;
  const owner = new GatewaySubscriptionOwner({
    rpc,
    state,
    applySessionSources: (...args) => applySessionSources(...args),
    refresh: (...args) => refresh(...args),
    isIgnoredEvent: isIgnoredMonitorEvent
  });

  const onEvent = (event) => {
    if (event?.type === "subscription_error") {
      // Only the subscription died — the control socket that carried this very
      // message is still up, so the Gateway has not disconnected and must not
      // be shown as red. Streaming pauses (amber) and we resubscribe at once.
      // No `notice` is broadcast: this is transient and self-healing, and
      // flashing it on every recoverable drop was the recurring message the
      // user saw. The amber "재연결 중" state is the durable signal instead.
      owner.markInactive();
      state.setConnection({
        connected: true,
        streaming: false,
        error: event.error ?? "Gateway event subscription failed",
        health: "degraded"
      });
      state.broadcast({ kind: "state", connected: state.connected, streaming: false, error: state.lastError });
      const retry = setTimeout(() => { void ensureSubscription(); }, 500);
      retry.unref?.();
      return;
    }
    if (event?.type === "subscription_gap") {
      owner.noteGap(event);
      state.broadcast({
        kind: "state",
        connected: true,
        streaming: false,
        streamHealth: state.streamHealth,
        diagnostics: state.diagnostics,
        error: state.lastError
      });
      void reconcileSubscription();
      return;
    }
    if (event?.type === "subscription_replay_truncated") {
      state.noteReplayTruncation(event);
      state.broadcast({
        kind: "state",
        connected: true,
        streaming: true,
        streamHealth: state.streamHealth,
        diagnostics: state.diagnostics,
        error: state.lastError
      });
      return;
    }
    if (isIgnoredMonitorEvent(event)) return;
    const changed = state.pushEvent(event);
    if (!changed.length && event.type !== "session_closed") return;
    queueEvents(event.sessionId, changed);
    if (event.type === "session_closed") {
      flushEvents();
      state.setGatewaySourceSessions(
        state.gatewaySourceSessions.filter((session) => session.sessionId !== event.sessionId)
      );
      state.removeSession(event.sessionId, { closed: true });
      state.broadcast({ kind: "session_removed", sessionId: event.sessionId });
    }
    // Session status flips (running/idle/waiting_*) live on the session record,
    // so nudge a refresh whenever a lifecycle event lands.
    if (!event.type?.endsWith("_chunk")) scheduleRefresh();
  };
  owner.onEvent = onEvent;

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
    try {
      const [sessions, tasks, inbox] = await Promise.all([
        rpc.call("session", { action: "list" }),
        rpc.call("task_list", {}),
        rpc.call("inbox", { action: "list" })
      ]);
      state.setGatewaySourceSessions(sessions.sessions ?? []);
      const { removedSessionIds, localEvents } = await applySessionSources();
      const recordsChanged = state.setRecords({ tasks: tasks.tasks ?? [], inbox: inbox.items ?? [] });
      const preserveHealth = state.streamHealth === "reconciling" || state.streamHealth === "degraded";
      state.setConnection({
        connected: true,
        streaming: state.streaming,
        error: preserveHealth ? state.lastError : null,
        health: preserveHealth ? state.streamHealth : undefined
      });
      if (state.revision !== beforeRevision || recordsChanged || !wasConnected) {
        state.broadcast({
          kind: "state",
          connected: true,
          streaming: state.streaming,
          sessions: [...state.sessions.values()],
          removedSessionIds,
          ...(localEvents ? { events: localEvents } : {}),
          tasks: state.tasks,
          inbox: state.inbox
        });
      }
    } catch (error) {
      let removedSessionIds = [];
      let localEvents = null;
      try {
        ({ removedSessionIds, localEvents } = await applySessionSources());
      } catch (projectionError) {
        // The RPC failure is already the primary connection error. A malformed
        // projection must not escape this recovery path as an unhandled
        // rejection and terminate the sidecar.
        console.error(`Session projection recovery failed: ${projectionError.message}`);
      }
      state.setConnection({ connected: false, streaming: state.streaming, error: error?.message ?? String(error) });
      state.broadcast({
        kind: "state",
        connected: false,
        streaming: state.streaming,
        error: state.lastError,
        sessions: [...state.sessions.values()],
        removedSessionIds,
        ...(localEvents ? { events: localEvents } : {})
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
    const merged = mergeMonitorSessions(state.gatewaySourceSessions, local.sessions, state.workerTopology, state.formerWorkerIds);
    const acceptedLocalIds = new Set(merged.filter((session) => session.source === "local").map((session) => session.sessionId));
    const events = Object.fromEntries(Object.entries(local.events).filter(([sessionId]) => acceptedLocalIds.has(sessionId)));
    const removedSessionIds = state.setSessions(merged);
    // Only the events that changed travel with the state frame; the app
    // upserts them by id (an event outside a transcript window is kept).
    const changedEvents = state.setExternalEvents(events);
    const localEvents = Object.keys(changedEvents).length ? changedEvents : null;
    return { removedSessionIds, changed: state.revision !== beforeRevision, localEvents };
  });

  async function refreshGatewayInfo() {
    try {
      const gateway = annotateRuntimeSplit(
        decodeGatewaySetup(await rpc.call("setup", {})),
        GATEWAY_RUNTIME_ROOT,
        EXPECTED_GATEWAY_BUILD_ID
      );
      if (state.setGateway(gateway)) state.broadcast({ kind: "gateway", gateway });
    } catch {
      // setup is best-effort metadata; session/event flow works without it.
    }
  }

  async function ensureSubscription() {
    const before = owner.status();
    try {
      await owner.ensure();
      if (owner.subscriptionActive && !before.active) {
        state.broadcast({
          kind: "state",
          connected: true,
          streaming: true,
          streamHealth: state.streamHealth,
          diagnostics: state.diagnostics,
          error: state.lastError
        });
      }
    } catch (error) {
      state.setConnection({
        connected: state.connected,
        streaming: false,
        error: error?.message ?? String(error),
        health: "degraded"
      });
      console.error(`Gateway connection failed: ${state.lastError}`);
    }
  }

  async function reconcileSubscription() {
    try {
      await owner.reconcile();
      const snapshot = state.snapshot();
      state.broadcast({
        kind: "state",
        connected: true,
        streaming: true,
        streamHealth: snapshot.streamHealth,
        diagnostics: snapshot.diagnostics,
        sessions: snapshot.sessions,
        events: snapshot.events,
        tasks: snapshot.tasks,
        inbox: snapshot.inbox
      });
    } catch (error) {
      state.setConnection({
        connected: state.connected,
        streaming: false,
        error: error?.message ?? String(error),
        health: "degraded"
      });
      const retry = setTimeout(() => { void reconcileSubscription(); }, 500);
      retry.unref?.();
    }
  }

  // Bind and announce the HTTP endpoint before connecting to Gateway or
  // scanning local transcript trees. The Swift app can render its shell and
  // subscribe immediately; the initial snapshot arrives asynchronously.
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
  if (HOOKS_ENABLED) {
    try {
      writeHookEndpoint(hookEndpointPath, { port, token: hookToken });
    } catch (error) {
      console.error(`Hook endpoint unavailable: ${error.message}`);
    }
    // Install and update time: a new build refreshes the hooks it ships,
    // unless the user turned them off in settings.
    try {
      const result = ensureHooks();
      if (result.errors && Object.keys(result.errors).length) {
        console.error(`Hook install incomplete: ${Object.values(result.errors).join("; ")}`);
      }
    } catch (error) {
      console.error(`Hook install failed: ${error.message}`);
    }
  }
  console.log(JSON.stringify({
    kind: "monitor_ready",
    schemaVersion: MONITOR_SCHEMA_VERSION,
    monitorApiVersion: MONITOR_API_VERSION,
    url: `http://${MONITOR_HOST}:${port}`,
    apiToken,
    rootId: identity.rootId,
    sidecarVersion: SIDECAR_VERSION,
    sidecarBuildId: SIDECAR_BUILD_ID,
    gatewayIdentity: gatewayIdentity(state, identity),
    capabilities: monitorCapabilities(state)
  }));

  void (async () => {
    await ensureSubscription();
    await refreshGatewayInfo();
    await refresh();
  })().catch((error) => console.error(`Initial monitor refresh failed: ${error.message}`));
  const interval = setInterval(() => {
    void ensureSubscription();
    void refresh();
    void refreshGatewayInfo();
  }, REFRESH_INTERVAL_MS);
  interval.unref();
  async function broadcastLocalChanges() {
    try {
      const { removedSessionIds, changed, localEvents } = await applySessionSources();
      if (!changed) return;
      state.broadcast({
        kind: "state",
        connected: state.connected,
        streaming: state.streaming,
        sessions: [...state.sessions.values()],
        removedSessionIds,
        ...(localEvents ? { events: localEvents } : {})
      });
    } catch (error) {
      // Local scanning is a nicety; a fault here must never take the Gateway
      // view down. Without this catch an unhandled rejection kills the process.
      console.error(`Local session refresh failed: ${error.message}`);
    }
  }
  const localInterval = setInterval(() => {
    void broadcastLocalChanges();
  }, localScanIntervalMs);
  localInterval.unref();

  // A hook arrived: its events go straight to the store, and the local scan
  // runs now instead of on its next tick so the status change is immediate.
  let hookRefreshTimer = null;
  const nudgeLocalRefresh = () => {
    if (hookRefreshTimer) return;
    hookRefreshTimer = setTimeout(() => {
      hookRefreshTimer = null;
      void broadcastLocalChanges();
    }, 50);
    hookRefreshTimer.unref?.();
  };

  async function handleHook(provider, request, response) {
    let payload;
    try {
      payload = await readJsonBody(request, MAX_HOOK_BODY_BYTES);
    } catch {
      response.writeHead(400).end();
      return;
    }
    // Answered before any work: the agent is waiting on this hook.
    response.writeHead(204).end();
    const recorded = hookSessions.record(provider, payload);
    if (!recorded) return;
    const changed = state.setExternalEvents({ [recorded.sessionId]: recorded.events });
    for (const [sessionId, events] of Object.entries(changed)) queueEvents(sessionId, events);
    nudgeLocalRefresh();
  }

  async function handleRequest(request, response) {
    const url = new URL(request.url, `http://${request.headers.host ?? "localhost"}`);
    const hookRoute = url.pathname.match(/^\/api\/hooks\/([a-z]+)$/);
    if (hookRoute && request.method === "POST") {
      if (!HOOKS_ENABLED || request.headers["x-agenlynk-hook-token"] !== hookToken || !HOOK_PROVIDERS.has(hookRoute[1])) {
        response.writeHead(401).end();
        return;
      }
      await handleHook(hookRoute[1], request, response);
      return;
    }
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
    if (url.pathname === "/api/frontdoors" && request.method === "GET") {
      sendJson(response, await readInstalledFrontdoors());
      return;
    }
    if (url.pathname === "/api/snapshot") {
      const now = Date.now();
      const tag = state.snapshotTag(now);
      if (request.headers["if-none-match"] === tag) {
        response.writeHead(304, { etag: tag, "cache-control": "no-store" });
        response.end();
        return;
      }
      response.writeHead(200, {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
        etag: tag
      });
      response.end(JSON.stringify(state.snapshot(now)));
      return;
    }
    if (url.pathname === "/api/stream") {
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive"
      });
      response.write("retry: 2000\n\n");
      state.addSseClient(response);
      request.on("close", () => state.removeSseClient(response));
      return;
    }
    const eventsRoute = url.pathname.match(/^\/api\/sessions\/([^/]+)\/events$/);
    if (eventsRoute && request.method === "GET") {
      // Older events than the snapshot carries, newest page first; served
      // from memory and then from persisted history.
      const sessionId = decodeURIComponent(eventsRoute[1]);
      const before = Number(url.searchParams.get("before"));
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 200, 1), 1_000);
      sendJson(response, {
        sessionId,
        events: state.store.page(sessionId, { before: Number.isFinite(before) && before > 0 ? before : Infinity, limit })
      });
      return;
    }
    if (url.pathname === "/api/hooks" && request.method === "GET") {
      sendJson(response, { receiving: HOOKS_ENABLED, lastReceivedAt: hookSessions.lastReceivedAt(), ...hookStatus() });
      return;
    }
    if (url.pathname === "/api/hooks" && request.method === "POST") {
      const body = await readJsonBody(request);
      const providers = Array.isArray(body.providers)
        ? body.providers.filter((provider) => INSTALLABLE_HOOK_PROVIDERS.includes(provider))
        : null;
      if (body.action !== "install" && body.action !== "uninstall") {
        response.writeHead(400, { "content-type": "application/json; charset=utf-8" });
        response.end('{"error":"action must be install or uninstall","code":"monitor_bad_request"}');
        return;
      }
      const only = providers?.length ? providers : null;
      const result = body.action === "install"
        ? installHooks({ only, consent: body.consent === true })
        : uninstallHooks({ only, decline: body.decline === true });
      sendJson(response, { receiving: HOOKS_ENABLED, lastReceivedAt: hookSessions.lastReceivedAt(), ...result });
      return;
    }
    if (url.pathname === "/api/history" && request.method === "GET") {
      // Newest first; pass the oldest updatedAt received as `before` to page.
      const since = Number(url.searchParams.get("since")) || 0;
      const before = Date.parse(url.searchParams.get("before") ?? "") || Number(url.searchParams.get("before")) || Number.MAX_SAFE_INTEGER;
      // (updatedAt, sessionId) is the cursor, so sessions sharing a timestamp
      // across a page boundary are not skipped.
      const beforeId = url.searchParams.get("beforeId") ?? null;
      const limit = Math.min(Math.max(Number(url.searchParams.get("limit")) || 50, 1), 500);
      const sessions = persistence ? persistence.readSessions({ since, before, beforeId, limit }) : [];
      sendJson(response, { sessions, hasMore: sessions.length === limit });
      return;
    }
    if (url.pathname === "/api/history/stats" && request.method === "GET") {
      sendJson(response, persistence ? persistence.stats() : diskHistoryWithoutStore());
      return;
    }
    if (url.pathname === "/api/history" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (body.action !== "clear") {
        response.writeHead(400, { "content-type": "application/json; charset=utf-8" });
        response.end('{"error":"action must be clear","code":"monitor_bad_request"}');
        return;
      }
      const live = new Set(state.sessions.keys());
      // With disk history off there is no store, but a file left from when it
      // was on is still the user's data: clearing removes the file itself.
      const deleted = persistence ? persistence.clear({ keep: live }) : removeDiskHistoryFiles();
      state.clearHistory();
      state.broadcast({ kind: "state", connected: state.connected, streaming: state.streaming, historyCleared: true });
      sendJson(response, { deleted, ...(persistence ? persistence.stats() : diskHistoryWithoutStore()) });
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
      if (!gatewayFeatureAvailable(state.gateway, "sessionConfig")) {
        sendJson(response, {
          ok: true,
          sessionId,
          configOptions: [],
          unavailableReason: state.gateway?.compatibility?.reason ?? "Gateway setup capability is unavailable"
        });
        return;
      }
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
        if (!isGatewayError(error, "CONTROL_ACCESS_DENIED")) throw error;
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
      if (!gatewayFeatureAvailable(state.gateway, "sessionConfig")) throw unavailableFeatureError("session config");
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
        activeValues: activeConfigValues()
      }));
      return;
    }
    if (url.pathname === "/api/gateway-config" && request.method === "POST") {
      const body = await readJsonBody(request);
      const action = body.action ?? "set";
      if (!new Set(["set", "reset"]).has(action)) throw new Error(`Unknown Gateway config action: ${action}`);
      // These are AgenLynk-owned launch settings. Gateway 1.4.0 intentionally
      // exposes no gateway_config RPC, so never probe an undeclared method.
      await updateGatewaySettings({
        statePath: identity.statePath,
        values: action === "set" ? body.values ?? {} : {},
        resetIds: action === "reset" ? body.ids ?? [] : []
      });
      const result = gatewaySettingsSnapshot({
        statePath: identity.statePath,
        activeValues: activeConfigValues()
      });
      sendJson(response, result);
      return;
    }
    // What a retention change would delete, counted without deleting it. The
    // app asks before saving a value that destroys data.
    if (url.pathname === "/api/retention-preview" && request.method === "POST") {
      throw unavailableFeatureError("retention preview");
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
      const decodedGateway = annotateRuntimeSplit(
        decodeGatewaySetup(gateway),
        GATEWAY_RUNTIME_ROOT,
        EXPECTED_GATEWAY_BUILD_ID
      );
      state.setGateway(decodedGateway);
      state.setConnection({ connected: true, streaming: state.streaming, error: null });
      state.broadcast({ kind: "gateway", gateway: decodedGateway });
    } finally {
      starter.close();
    }
  }

  let shuttingDown = false;
  let parentWatch = null;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    clearInterval(interval);
    clearInterval(localInterval);
    clearInterval(historyPrune);
    flushEvents();
    persistence?.close();
    saveWorkerLedger?.flush();
    removeHookEndpoint(hookEndpointPath, hookToken);
    if (parentWatch) clearInterval(parentWatch);
    state.closeSseClients();
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
  const sessions = hookSessions.merge(await collectLocalSessions());
  if (!sessions.length) return { sessions: [], events: {} };
  try {
    // One pipeline for every provider: the scanner found the sessions and
    // their transcripts, the timeline tails and normalizes them.
    const { results } = localTimeline ? await localTimeline.update(sessions) : { results: new Map() };
    return projectLocalSnapshot({ sessions }, results);
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

// Missing Gateway setup values (e.g. before the first successful "setup"
// call) surface as null rather than being omitted, per the shared wire
// contract; apiToken/control token are never part of this shape.
// Which agents already have the "agent-acp" Control MCP installed. The ground
// truth is each agent's own config, NOT install.json's managedMcp record —
// managedMcp only lists what this app installed, so an MCP the user set up any
// other way (or before this app tracked it) would read as "not installed" and
// be wrongly offered for install. The section header `[mcp_servers.agent-acp]`
// (codex/grok TOML) or the `mcpServers["agent-acp"]` key (claude JSON) is what
// actually gates the Frontdoor.
const FRONT_DOOR_AGENTS = new Set(["codex", "claude", "grok"]);
// Matches the control section but not agent-acp-guide (next char is `-`).
const CONTROL_MCP_TOML = /^\[mcp_servers\.agent-acp[\].]/m;

async function tomlHasControlMcp(path) {
  try {
    return CONTROL_MCP_TOML.test(await readFile(path, "utf8"));
  } catch {
    return false;
  }
}

async function claudeJsonHasControlMcp(path) {
  try {
    const raw = JSON.parse(await readFile(path, "utf8"));
    return Boolean(raw?.mcpServers && raw.mcpServers["agent-acp"]);
  } catch {
    return false;
  }
}

async function readInstalledFrontdoors() {
  const home = homedir();
  const codexHome = process.env.CODEX_HOME || join(home, ".codex");
  const grokHome = process.env.GROK_HOME || join(home, ".grok");
  const [codex, grok, claude] = await Promise.all([
    tomlHasControlMcp(join(codexHome, "config.toml")),
    tomlHasControlMcp(join(grokHome, "config.toml")),
    claudeJsonHasControlMcp(join(home, ".claude.json"))
  ]);
  const installed = [
    ...(codex ? ["codex"] : []),
    ...(claude ? ["claude"] : []),
    ...(grok ? ["grok"] : [])
  ];
  // The exclusive primary is still whatever install.json recorded; it is only
  // a label, and a missing/invalid file just means "no primary".
  let primary = null;
  try {
    const raw = JSON.parse(await readFile(defaultInstallStatePath(), "utf8"));
    if (FRONT_DOOR_AGENTS.has(raw?.frontDoor)) primary = raw.frontDoor;
  } catch {
    // no install.json → no primary
  }
  return { primary, installed };
}

function gatewayIdentity(state, identity) {
  return {
    rootId: identity.rootId ?? null,
    gatewayApiVersion: state.gateway?.gatewayApiVersion ?? null,
    gatewayVersion: state.gateway?.gatewayVersion ?? null,
    gatewayBuildId: state.gateway?.gatewayBuildId ?? null
  };
}

function monitorCapabilities(state) {
  return {
    ...(state.gateway?.capabilities ?? {}),
    gatewayCompatibility: state.gateway?.compatibility ?? {
      status: "unknown",
      reason: "Gateway setup has not completed",
      features: {}
    }
  };
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
export function annotateRuntimeSplit(gateway, monitorRuntimeRoot, monitorBuildId = null) {
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
  if (monitorBuildId) {
    return {
      ...gateway,
      runtimeIdentity: daemonBuildId
        ? { status: "verified", daemonBuildId, monitorBuildId }
        : { status: "unverified", monitorBuildId, reason: "Gateway setup does not expose gatewayBuildId" }
    };
  }
  return gateway;
}

function expectedGatewayBuildId(gatewayRuntimeRoot) {
  if (!gatewayRuntimeRoot) return null;
  try {
    const manifest = JSON.parse(readFileSync(join(gatewayRuntimeRoot, "..", "runtime-manifest.json"), "utf8"));
    return typeof manifest.gatewayBuildId === "string" && manifest.gatewayBuildId
      ? manifest.gatewayBuildId
      : null;
  } catch {
    return null;
  }
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

const DISK_HISTORY_SUFFIXES = ["", "-wal", "-shm"];

/** Size of a monitor.db this process does not have open (disk history off). */
function diskHistoryFileBytes(path = defaultMonitorDatabasePath()) {
  let bytes = 0;
  let exists = false;
  for (const suffix of DISK_HISTORY_SUFFIXES) {
    try {
      bytes += statSync(`${path}${suffix}`).size;
      exists = true;
    } catch {
      // Not present.
    }
  }
  return { exists, bytes };
}

function removeDiskHistoryFiles(path = defaultMonitorDatabasePath()) {
  for (const suffix of DISK_HISTORY_SUFFIXES) rmSync(`${path}${suffix}`, { force: true });
  return 0;
}

async function readJsonBody(request, limit = 64 * 1024) {
  const chunks = [];
  let bytes = 0;
  for await (const chunk of request) {
    bytes += chunk.length;
    if (bytes > limit) throw new Error("request body is too large");
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
