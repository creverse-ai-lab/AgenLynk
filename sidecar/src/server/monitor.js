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
import { readFileSync } from "node:fs";
import { createServer } from "node:http";
import { basename, dirname, join } from "node:path";
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
import { readInstalledFrontdoors } from "../app/frontdoor-configs.js";
import { identityFrom, watchIdentity } from "../app/identity-watch.js";
import { terminateLockedDaemon } from "../app/daemon-lock.js";
import { describeGatewayError } from "../app/gateway-errors.js";
import { delegatorSkillStatus, SKILL_AGENTS, syncDelegatorSkill } from "../app/delegator-skill.js";
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
import { LocalEventDelivery, mergeMonitorSessions, projectLocalSnapshot } from "../local-monitor.js";
import { LocalAgentScanner } from "../local-agents/index.js";
import { codexApprovesAutomatically } from "../local-agents/codex.js";
import { hookLineageHeaders, ProcessLineage } from "../local-agents/lineage.js";
import { LocalTimeline } from "../normalize/local-timeline.js";
import {
  SqliteMonitorStore,
  databaseFileBytes,
  defaultMonitorDatabasePath,
  removeDatabaseFiles
} from "../store/sqlite-store.js";
import { HookSessions, processAliveFrom } from "../hooks/registry.js";
import { defaultWorkerLedgerPath, readWorkerLedger, workerLedgerWriter } from "../store/worker-ledger.js";
import { CHAT_POLL_MAX_WAIT_MS, chatCancelArgs, chatFrontdoor, chatOpenArgs, chatPermissionArgs, chatPollArgs, chatPromptArgs } from "../app/notch-chat.js";
import { StopReplies, isFrontdoorStop, stopReplyDecision } from "../hooks/stop-replies.js";
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
// Like hooks, only the app turns this on: a test or dev sidecar must not
// rewrite the skills in the user's agent homes.
const SKILL_SYNC_ENABLED = booleanEnv("ACP_GATEWAY_MONITOR_SKILL_SYNC", false);
const MAX_HOOK_BODY_BYTES = 1024 * 1024;
// How long a hook answer may wait for its process tree to be read.
const HOOK_LINEAGE_BUDGET_MS = 250;
// How long a Codex PermissionRequest may wait to learn its approval mode.
const APPROVAL_MODE_BUDGET_MS = 250;
const HOOK_PROVIDERS = new Set(["claude", "codex", "grok"]);
const GATEWAY_RUNTIME_ROOT = process.env.ACP_GATEWAY_ACTIVE_ROOT ?? null;
const EXPECTED_GATEWAY_BUILD_ID = expectedGatewayBuildId(GATEWAY_RUNTIME_ROOT);
const EXPECTED_GATEWAY_VERSION = expectedGatewayManifestField(GATEWAY_RUNTIME_ROOT, "gatewayVersion");
// A superseded daemon is retried at most this often: shutdown_if_idle refuses
// while work is in flight, and a respawn that is still split must not loop.
const IDLE_RESTART_BACKOFF_MS = 5 * 60_000;
// Initialized inside main() so corrupt settings are reported through its
// guarded startup path instead of throwing while this module is imported.
let localScanner = null;
let localTimeline = null;
// Live facts from agent hooks, overlaid on every local scan. Replaced in
// main() once the retention setting is known.
let hookSessions = new HookSessions();
// Open notch reply windows on Frontdoor Stops (see hooks/stop-replies.js).
const stopReplies = new StopReplies();
// Lineage resolver for hooks when the local scanner (which owns one) is off.
let hookLineage = null;

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
  const path = defaultInstallStatePath();
  if (envToken && envRootId) return { token: envToken, rootId: envRootId, statePath: path, fromEnv: true };
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
  return {
    token: envToken ?? identity.token,
    rootId: envRootId ?? identity.rootId,
    statePath: path,
    // Only a token from the environment makes install.json's irrelevant.
    fromEnv: Boolean(envToken)
  };
}

// The app starts a new monitor when this one exits; the new one reads the
// identity install.json holds then.
const IDENTITY_CHANGED_EXIT = 75;

/**
 * Whether a Codex PermissionRequest will be decided without its user (see
 * codexApprovesAutomatically). Read only for that one hook, and never for
 * longer than the hook may wait: unknown means "asks", as before.
 */
async function hookApprovalIsAutomatic(provider, payload) {
  if (provider !== "codex" || payload?.hook_event_name !== "PermissionRequest") return false;
  const answer = codexApprovesAutomatically(payload.transcript_path, payload.turn_id).catch(() => false);
  const timeout = new Promise((resolve) => setTimeout(() => resolve(false), APPROVAL_MODE_BUDGET_MS).unref?.());
  return Promise.race([answer, timeout]);
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
  hookLineage = localScanner ? null : new ProcessLineage();
  const lineageForHooks = localScanner?.lineage ?? hookLineage;
  hookSessions = new HookSessions({
    staleAfterMs: monitorSettings.localSessionRetentionMs,
    isAlive: processAliveFrom(() => lineageForHooks?.freshTable() ?? null)
  });
  localTimeline = localScanner
    ? new LocalTimeline({
      codexRecords: (sessionId) => localScanner.conversationRecords(sessionId),
      // Claude and Grok windows follow the same user setting as Codex's.
      windowMs: monitorSettings.localTranscriptWindowMs,
      maxRecords: monitorSettings.localTranscriptRecordLimit
    })
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
    const file = databaseFileBytes(path);
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
    // Sessions still in memory are kept too: Gateway events can be persisted
    // before the session list names them.
    persistence?.prune({ keep: new Set([...state.sessions.keys(), ...state.store.sessionIds()]) });
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
    // The owner's pass is the one an overlapping local tick now waits behind
    // (it is handed the pass after), so what this pass changes is broadcast
    // here; otherwise it reached no client until something changed again.
    applySessionSources: async () => {
      const result = await applySessionSources();
      if (result.changed) broadcastSessionSources(result);
      return result;
    },
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
  // One malformed event must not take the process down: it arrives from the
  // socket's own handler, and the app would restart a sidecar that a replayed
  // subscription then feeds the same event again.
  owner.onEvent = (event) => {
    try {
      onEvent(event);
    } catch (error) {
      console.error(`Gateway event ${event?.type ?? "?"} for ${event?.sessionId ?? "?"} was skipped: ${error?.stack ?? error}`);
    }
  };

  // State frames carry the session list only when it changed since the last
  // frame: every second's frame used to resend every session, and the app
  // re-decoded and compared them all. A client that (re)connects fetches a
  // snapshot, so it never depends on a frame it missed.
  let sentSessionsVersion = -1;
  const changedSessions = () => {
    if (state.sessionsVersion === sentSessionsVersion) return {};
    sentSessionsVersion = state.sessionsVersion;
    return { sessions: [...state.sessions.values()] };
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
    try {
      const [sessions, tasks, inbox] = await Promise.all([
        rpc.call("session", { action: "list" }),
        rpc.call("task_list", {}),
        rpc.call("inbox", { action: "list" })
      ]);
      state.setGatewaySourceSessions(sessions.sessions ?? []);
      // The 1 s local loop already scans the transcripts; a Gateway refresh
      // only re-merges with its last result instead of scanning again.
      const { removedSessionIds, localEvents } = await applySessionSources({ reuseLocal: true });
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
          ...changedSessions(),
          removedSessionIds,
          ...(localEvents ? { events: localEvents } : {}),
          ...(recordsChanged || !wasConnected ? { tasks: state.tasks, inbox: state.inbox } : {})
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
      // A daemon restarted after a token rotation refuses the old token.
      if (isGatewayError(error, "CONTROL_ACCESS_DENIED")) identityWatch.check();
      state.setConnection({ connected: false, streaming: state.streaming, error: describeGatewayError(error) });
      state.broadcast({
        kind: "state",
        connected: false,
        streaming: state.streaming,
        error: state.lastError,
        ...changedSessions(),
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
  const localDelivery = new LocalEventDelivery();
  // A Gateway refresh merges against the last local scan rather than scanning
  // again (its events were handed over by the pass that read them). Any other
  // caller wants a fresh scan, and so does the queued pass that serves it,
  // even if a Gateway refresh queued behind the same pass.
  let freshScanWanted = true;
  let lastLocal = null;
  const runSessionSources = queuedSingleFlight(async () => {
    const beforeRevision = state.revision;
    const reuse = !freshScanWanted && lastLocal;
    freshScanWanted = false;
    const local = reuse ? lastLocal : (lastLocal = await readLocalProjection());
    const lineage = localScanner?.lineage ?? hookLineage;
    const merged = mergeMonitorSessions(
      state.gatewaySourceSessions, local.sessions, state.workerTopology, state.formerWorkerIds,
      // The live pid file names the session a Claude Main holds now.
      (caller) => (caller?.provider === "claude" && caller.pid ? lineage?.claudeRecord(caller.pid)?.sessionId ?? null : null)
    );
    const acceptedLocalIds = new Set(merged.filter((session) => session.source === "local").map((session) => session.sessionId));
    // Only timelines that changed since they were last handed over: an idle
    // session's window is otherwise re-merged event by event every second.
    // A reused scan's events were handed over already; the next fresh scan
    // hands over any session this merge newly accepted.
    const events = reuse ? {} : localDelivery.select(local.events, local.changedSessionIds, acceptedLocalIds);
    const removedSessionIds = state.setSessions(merged);
    // Only the events that changed travel with the state frame; the app
    // upserts them by id (an event outside a transcript window is kept).
    const changedEvents = state.setExternalEvents(events);
    const localEvents = Object.keys(changedEvents).length ? changedEvents : null;
    return { removedSessionIds, changed: state.revision !== beforeRevision, localEvents };
  });
  const applySessionSources = ({ reuseLocal = false } = {}) => {
    if (!reuseLocal) freshScanWanted = true;
    return runSessionSources();
  };

  async function refreshGatewayInfo() {
    let gateway;
    try {
      gateway = annotateSupersededDaemon(annotateRuntimeSplit(
        decodeGatewaySetup(await rpc.call("setup", {})),
        GATEWAY_RUNTIME_ROOT,
        EXPECTED_GATEWAY_BUILD_ID
      ), EXPECTED_GATEWAY_VERSION, state.restartBlockers());
      if (state.setGateway(gateway)) state.broadcast({ kind: "gateway", gateway });
    } catch {
      // setup is best-effort metadata; session/event flow works without it.
      return;
    }
    await restartSupersededDaemon(gateway);
  }

  // A runtime update only moves runtime/current; the daemon already running
  // keeps serving the old version until something restarts it (a 1.4.0
  // daemon outlived its runtime by days). Restart it once nothing is in
  // flight, idle-safely: shutdown_if_idle refuses while the daemon is busy.
  let idleRestartAfter = 0;
  async function restartSupersededDaemon(gateway) {
    if (gateway?.supersededDaemon?.plan !== "restart" || Date.now() < idleRestartAfter) return;
    idleRestartAfter = Date.now() + IDLE_RESTART_BACKOFF_MS;
    try {
      await restartGateway("shutdown_if_idle");
      console.error(`Restarted superseded Gateway ${gateway.gatewayVersion} daemon from the ${EXPECTED_GATEWAY_VERSION} runtime`);
    } catch (error) {
      console.error(`Superseded Gateway daemon restart deferred: ${error.message}`);
    }
  }

  async function ensureSubscription() {
    const before = owner.status();
    try {
      await owner.ensure();
      if (owner.subscriptionActive && !before.active) {
        // A (re)connected daemon may be a different one: read its setup now.
        void refreshGatewayInfo();
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
      if (isGatewayError(error, "CONTROL_ACCESS_DENIED")) identityWatch.check();
      state.setConnection({
        connected: state.connected,
        streaming: false,
        error: describeGatewayError(error),
        health: "degraded"
      });
      console.error(`Gateway connection failed: ${state.lastError}`);
    }
  }

  // Gap markers can arrive in bursts; the owner coalesces them into one
  // running and at most one queued reconciliation, and a failure keeps a
  // single retry timer, not one per marker.
  let reconcileRetry = null;
  async function reconcileSubscription() {
    if (reconcileRetry) {
      clearTimeout(reconcileRetry);
      reconcileRetry = null;
    }
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
      if (isGatewayError(error, "CONTROL_ACCESS_DENIED")) identityWatch.check();
      state.setConnection({
        connected: state.connected,
        streaming: false,
        error: describeGatewayError(error),
        health: "degraded"
      });
      if (!reconcileRetry) {
        reconcileRetry = setTimeout(() => {
          reconcileRetry = null;
          void reconcileSubscription();
        }, 500);
        reconcileRetry.unref?.();
      }
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
      response.end(JSON.stringify({ error: describeGatewayError(error), ...(code ? { code } : {}) }));
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
  // Every start brings the delegation skill in each Main CLI up to the one
  // this build ships; a copy someone edited is left alone (see
  // delegator-skill.js).
  if (SKILL_SYNC_ENABLED) {
    void syncDelegatorSkill()
      .then((result) => {
        if (Object.keys(result.errors).length) console.error(`Skill update incomplete: ${Object.values(result.errors).join("; ")}`);
      })
      .catch((error) => console.error(`Skill update failed: ${error.message}`));
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
  // `setup` (versions, capabilities, health) rarely changes: every 20th tick
  // (60 s) instead of every 3 s; a (re)connect refreshes it at once too.
  let ticks = 0;
  const interval = setInterval(() => {
    void ensureSubscription();
    void refresh();
    ticks += 1;
    if (ticks % 20 === 0) {
      void refreshGatewayInfo();
      // Expired history otherwise leaves memory only when a snapshot is
      // built, i.e. only while the app keeps asking for one.
      state.pruneHistory();
    }
  }, REFRESH_INTERVAL_MS);
  interval.unref();
  function broadcastSessionSources({ removedSessionIds, localEvents }) {
    state.broadcast({
      kind: "state",
      connected: state.connected,
      streaming: state.streaming,
      ...changedSessions(),
      removedSessionIds,
      ...(localEvents ? { events: localEvents } : {})
    });
  }
  async function broadcastLocalChanges() {
    try {
      const result = await applySessionSources();
      if (result.changed) broadcastSessionSources(result);
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
    // Watched from the start: a hook killed while this is still reading or
    // resolving lineage must not leave a reply window open behind it.
    let hookGone = false;
    let heldSlotId = null;
    response.on("close", () => {
      hookGone = true;
      if (heldSlotId) stopReplies.dismiss(heldSlotId);
    });
    let payload;
    try {
      payload = await readJsonBody(request, MAX_HOOK_BODY_BYTES);
    } catch {
      response.writeHead(400).end();
      return;
    }
    const automaticApproval = await hookApprovalIsAutomatic(provider, payload);
    const recorded = hookSessions.record(provider, payload, Date.now(), hookLineageHeaders(request.headers), { automaticApproval });
    // Which session launched this one (a shell-launched agent is a worker)
    // is read from the process tree while the hook's shell is still alive,
    // i.e. before answering: a short `claude -p` is often gone by the time
    // a deferred `ps` runs, and then only its own id is left to go on. It is
    // bounded and runs only until a session's lineage is known.
    if (recorded && !state.formerWorkerIds.has(recorded.localSessionId)) {
      await Promise.race([
        hookSessions.resolveLineage(recorded.key, localScanner?.lineage ?? hookLineage),
        new Promise((resolve) => setTimeout(resolve, HOOK_LINEAGE_BUDGET_MS).unref?.())
      ]);
    }
    const replyTarget = recorded && isFrontdoorStop(provider, payload) && stopReplies.enabled && state.sseClients.size > 0
      && !state.formerWorkerIds.has(recorded.localSessionId)
      ? hookSessions.replyTarget(recorded.key)
      : null;
    // The agent is waiting on this hook; everything else happens after,
    // except for a Frontdoor's Stop that the notch may still answer.
    if (!replyTarget?.eligible) response.writeHead(204).end();
    if (!recorded) return;
    // A Gateway worker's own CLI runs the same hooks; its timeline is the
    // Gateway's, and these events would sit in a bucket nothing ever lists.
    if (state.formerWorkerIds.has(recorded.localSessionId)) return;
    // A held-back session (no activity, no transcript) is not listed, so its
    // events would sit in a bucket nothing ever shows.
    if (!recorded.heldBack) {
      const changed = state.setExternalEvents({ [recorded.sessionId]: recorded.events });
      for (const [sessionId, events] of Object.entries(changed)) queueEvents(sessionId, events);
    }
    nudgeLocalRefresh();
    if (replyTarget?.eligible && !hookGone) {
      await holdForReply(recorded, replyTarget, payload, response, (id) => { heldSlotId = id; });
    } else if (replyTarget?.eligible && !response.writableEnded) {
      response.writeHead(204).end();
    }
  }

  // Holds an eligible Stop open while the notch offers a reply box. The hook
  // prints whatever this answers; an empty answer lets the agent stop.
  async function holdForReply(recorded, target, payload, response, onOpen) {
    const { slot, reply } = stopReplies.open({
      provider: target.provider, sessionId: recorded.sessionId, cwd: target.cwd, payload,
      backgroundTasks: target.backgroundTasks
    });
    onOpen(slot.id);
    state.broadcast({ kind: "reply_slot", slot });
    const text = await reply;
    state.broadcast({ kind: "reply_slot_closed", id: slot.id, answered: text != null });
    if (response.writableEnded || response.destroyed) return;
    if (text == null) {
      response.writeHead(204).end();
      return;
    }
    response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
    response.end(stopReplyDecision(text));
    hookSessions.markRunning(recorded.key);
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
      sendJson(response, await readInstalledFrontdoors({ installStatePath: defaultInstallStatePath() }));
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
      response.end(state.snapshotJson(now));
      return;
    }
    if (url.pathname === "/api/stream") {
      response.writeHead(200, {
        "content-type": "text/event-stream",
        "cache-control": "no-cache",
        connection: "keep-alive"
      });
      response.write("retry: 2000\n\n");
      // The list as it is now: later state frames carry it only when it
      // changes, and the snapshot this client fetched may predate this
      // stream (a change in between would otherwise never reach it).
      response.write(`data: ${JSON.stringify({
        kind: "state",
        connected: state.connected,
        streaming: state.streaming,
        sessions: [...state.sessions.values()],
        tasks: state.tasks,
        inbox: state.inbox,
        revision: state.revision,
        schemaVersion: MONITOR_SCHEMA_VERSION,
        monitorApiVersion: MONITOR_API_VERSION
      })}\n\n`);
      state.addSseClient(response);
      // A reconnecting app still gets the reply windows that are open.
      for (const slot of stopReplies.list()) {
        response.write(`data: ${JSON.stringify({ kind: "reply_slot", slot })}\n\n`);
      }
      request.on("close", () => {
        state.removeSseClient(response);
        // Nobody left to answer: release every held Stop now.
        if (state.sseClients.size === 0) stopReplies.closeAll();
      });
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
    if (url.pathname === "/api/skill" && request.method === "GET") {
      sendJson(response, await delegatorSkillStatus());
      return;
    }
    if (url.pathname === "/api/skill" && request.method === "POST") {
      // `install`: agents to add it to; `force`: agents whose edited copy
      // the user chose to replace.
      const body = await readJsonBody(request);
      const agents = (list) => (Array.isArray(list) ? list.filter((agent) => SKILL_AGENTS.includes(agent)) : []);
      sendJson(response, await syncDelegatorSkill({ install: agents(body.install), force: agents(body.force) }));
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
    // Notch chat. Opening, prompting and answering are Main actions, so they
    // go over a short-lived control connection like the settings mutations;
    // poll is a read and stays on the observer connection.
    // Notch replies to a Frontdoor's Stop: answer, dismiss or keep waiting.
    if (url.pathname === "/api/notch/reply" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (typeof body.id !== "string" || !body.id) throw new Error("id is required");
      let ok;
      if (body.action === "answer") ok = stopReplies.answer(body.id, body.text);
      else if (body.action === "dismiss") ok = stopReplies.dismiss(body.id);
      else if (body.action === "extend") {
        const slot = stopReplies.extend(body.id);
        sendJson(response, { ok: Boolean(slot), slot });
        return;
      } else throw new Error("action must be answer, dismiss or extend");
      sendJson(response, { ok });
      return;
    }
    if (url.pathname === "/api/notch/reply-settings" && request.method === "POST") {
      const body = await readJsonBody(request);
      if (typeof body.enabled !== "boolean") throw new Error("enabled must be a boolean");
      stopReplies.enabled = body.enabled;
      if (!body.enabled) stopReplies.closeAll();
      sendJson(response, { ok: true, enabled: stopReplies.enabled });
      return;
    }
    if (url.pathname === "/api/chat/open" && request.method === "POST") {
      const body = await readJsonBody(request);
      const frontdoor = chatFrontdoor(body);
      // Only a live Frontdoor the monitor lists can own a Worker; a gone one
      // would leave the Worker unattributed.
      const owner = state.sessions.get(frontdoor.monitorSessionId);
      if (!owner || owner.role !== "frontdoor" || owner.status === "closed") {
        const error = new Error("그 Frontdoor는 더 이상 실행 중이 아닙니다. 다른 Frontdoor를 골라 주세요.");
        error.statusCode = 409;
        error.code = "monitor_frontdoor_gone";
        throw error;
      }
      // The Worker is the Frontdoor's: Gateway 1.6+ records the caller as
      // openedBy; the topology is also set here so an older Gateway's worker
      // joins the same Frontdoor instead of "연결 미확인".
      const caller = { provider: frontdoor.provider, sessionId: frontdoor.sessionId, instanceId: `agenlynk-notch-${frontdoor.sessionId}`.slice(0, 128) };
      const result = await controlCall("session_open", chatOpenArgs(body), 120_000, caller);
      if (typeof result?.sessionId === "string") {
        const parent = state.sessions.get(frontdoor.monitorSessionId);
        state.workerTopology.set(result.sessionId, {
          opener: frontdoor.provider,
          openerInstanceId: parent?.openerInstanceId ?? frontdoor.sessionId,
          parentSessionId: frontdoor.monitorSessionId
        });
      }
      sendJson(response, result);
      scheduleRefresh();
      return;
    }
    if (url.pathname === "/api/chat/prompt" && request.method === "POST") {
      sendJson(response, await controlCall("prompt", chatPromptArgs(await readJsonBody(request))));
      return;
    }
    if (url.pathname === "/api/chat/poll" && request.method === "GET") {
      const args = chatPollArgs(url.searchParams);
      sendJson(response, await rpc.call("poll", args, CHAT_POLL_MAX_WAIT_MS + 10_000));
      return;
    }
    if (url.pathname === "/api/chat/permission" && request.method === "POST") {
      sendJson(response, await controlCall("permission", chatPermissionArgs(await readJsonBody(request))));
      return;
    }
    // A chat abandoned while its session was opening: close that Worker.
    if (url.pathname === "/api/chat/close" && request.method === "POST") {
      const { sessionId } = chatCancelArgs(await readJsonBody(request));
      sendJson(response, await controlCall("session", { action: "close", sessionId }));
      scheduleRefresh();
      return;
    }
    if (url.pathname === "/api/chat/cancel" && request.method === "POST") {
      sendJson(response, await controlCall("cancel", chatCancelArgs(await readJsonBody(request))));
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

  async function controlCall(method, args, timeoutMs, caller = null) {
    const control = new GatewayRpcClient({
      token: identity.token,
      rootId: identity.rootId,
      access: "control",
      autoStart: false,
      ...(caller ? { caller } : {})
    });
    try {
      return await control.call(method, args, timeoutMs);
    } catch (error) {
      // Refused because the token was rotated under this monitor.
      if (isGatewayError(error, "CONTROL_ACCESS_DENIED")) identityWatch.check();
      throw error;
    } finally {
      control.close();
    }
  }

  // One restart at a time: the automatic one for a superseded daemon and the
  // user's safe restart would otherwise race to stop and respawn it.
  let restartInFlight = null;
  function restartGateway(method = "daemon_shutdown") {
    restartInFlight ??= restartGatewayOnce(method).finally(() => { restartInFlight = null; });
    return restartInFlight;
  }

  async function restartGatewayOnce(method) {
    try {
      await controlCall(method, {});
    } catch (error) {
      // The person's restart of a daemon that still runs with the token from
      // before a rotation: it refuses this monitor's, so it is ended by its
      // lock pid. The automatic idle restart never goes this far.
      if (method !== "daemon_shutdown" || !isGatewayError(error, "CONTROL_ACCESS_DENIED")
        || !await terminateLockedDaemon(gatewaySocketPath())) throw error;
    }
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
      const decodedGateway = annotateSupersededDaemon(annotateRuntimeSplit(
        decodeGatewaySetup(gateway),
        GATEWAY_RUNTIME_ROOT,
        EXPECTED_GATEWAY_BUILD_ID
      ), EXPECTED_GATEWAY_VERSION, state.restartBlockers());
      state.setGateway(decodedGateway);
      state.setConnection({ connected: true, streaming: state.streaming, error: null });
      state.broadcast({ kind: "gateway", gateway: decodedGateway });
    } finally {
      starter.close();
    }
  }

  let shuttingDown = false;
  let parentWatch = null;
  let identityWatch = { stop() {}, check() {} };
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    identityWatch.stop();
    clearInterval(interval);
    clearInterval(localInterval);
    clearInterval(historyPrune);
    flushEvents();
    persistence?.close();
    saveWorkerLedger?.flush();
    removeHookEndpoint(hookEndpointPath, hookToken);
    if (parentWatch) clearInterval(parentWatch);
    // Held Stops first: their agents must not wait out a window nobody can
    // answer, and server.close() would wait for them.
    stopReplies.closeAll();
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
  function restartForIdentity() {
    if (shuttingDown) return;
    console.error("Gateway identity in install.json changed (token rotated); restarting the monitor with the new one");
    void shutdown().finally(() => process.exit(IDENTITY_CHANGED_EXIT));
  }
  // Compared file to file: a root id given in the environment is not a change.
  if (!identity.fromEnv) {
    identityWatch = watchIdentity(identity.statePath, identityFrom(identity.statePath) ?? identity, restartForIdentity);
  }
  // A promise nothing awaited failing is logged, not fatal: the loops that
  // fire and forget recover on their next pass.
  process.on("unhandledRejection", (reason) => {
    console.error(`Unhandled rejection: ${reason?.stack ?? reason}`);
  });
  process.on("SIGINT", () => void shutdown().finally(() => process.exit(0)));
  process.on("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
}

async function readLocalProjection() {
  const sessions = hookSessions.merge(await collectLocalSessions());
  // A Grok sub-agent only a hook reported carries the hook's lineage parent
  // (its parent's launcher); Grok's own record of the parent replaces it.
  await localScanner?.annotateGrokSubagents(sessions);
  // No early return for an empty list: the timeline's update is also where
  // the tails and windows of sessions that left expire.
  try {
    // One pipeline for every provider: the scanner found the sessions and
    // their transcripts, the timeline tails and normalizes them.
    const { results, changed } = localTimeline
      ? await localTimeline.update(sessions)
      : { results: new Map(), changed: new Set() };
    return {
      ...projectLocalSnapshot({ sessions }, results),
      changedSessionIds: new Set([...changed].map((key) => `local:${key}`))
    };
  } catch (error) {
    console.error(`Local session projection ignored: ${error.message}`);
    return { sessions: [], events: {}, changedSessionIds: new Set() };
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
  return expectedGatewayManifestField(gatewayRuntimeRoot, "gatewayBuildId");
}

function expectedGatewayManifestField(gatewayRuntimeRoot, field) {
  if (!gatewayRuntimeRoot) return null;
  try {
    // The version root: <version>/gateway (runtime tarball) or
    // <version>/node_modules/acp-gateway-daemon (npm package).
    const versionRoot = join(gatewayRuntimeRoot, basename(dirname(gatewayRuntimeRoot)) === "node_modules" ? "../.." : "..");
    const manifest = JSON.parse(readFileSync(join(versionRoot, "runtime-manifest.json"), "utf8"));
    return typeof manifest[field] === "string" && manifest[field] ? manifest[field] : null;
  } catch {
    return null;
  }
}

// shutdown_if_idle first shipped in Gateway 1.5.0; an older daemon rejects it.
const IDLE_SHUTDOWN_SINCE = "1.5.0";

/** -1/0/1 for two x.y.z release labels, or null when either does not parse. */
export function compareReleases(left, right) {
  const parse = (value) => /^(\d+)\.(\d+)\.(\d+)/.exec(String(value ?? ""))?.slice(1).map(Number) ?? null;
  const a = parse(left);
  const b = parse(right);
  if (!a || !b) return null;
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] < b[index] ? -1 : 1;
  }
  return 0;
}

/**
 * Marks a split whose daemon is an older release than this monitor's runtime
 * (the daemon outlived a runtime update) with what to do about it:
 * - "restart": restart it now with shutdown_if_idle,
 * - "blocked": the same, once the listed work finishes,
 * - "manual": it predates shutdown_if_idle, so only the user's safe restart
 *   (which checks for work in flight itself) may stop it.
 * A daemon that is newer, or whose version does not order, is left alone:
 * that is a dev checkout, not an update left half done.
 */
export function annotateSupersededDaemon(gateway, runtimeVersion, blockers = []) {
  if (!gateway?.runtimeSplit || compareReleases(gateway.gatewayVersion, runtimeVersion) !== -1) return gateway;
  const plan = compareReleases(gateway.gatewayVersion, IDLE_SHUTDOWN_SINCE) === -1
    ? "manual"
    : blockers.length ? "blocked" : "restart";
  return {
    ...gateway,
    supersededDaemon: { daemonVersion: gateway.gatewayVersion, runtimeVersion, plan, ...(plan === "blocked" ? { blockers } : {}) }
  };
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

/** Deletes a monitor.db this process does not have open (disk history off). */
function removeDiskHistoryFiles(path = defaultMonitorDatabasePath()) {
  removeDatabaseFiles(path);
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
