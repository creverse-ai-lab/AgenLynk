function isoTimestamp(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return new Date().toISOString();
  return new Date(seconds * 1_000).toISOString();
}

// Scanner states -> the canonical (Gateway) status vocabulary.
function monitorStatus(value) {
  switch (value) {
    case "running": return "running";
    case "needs_input": return "waiting_input";
    case "needs_permission": return "waiting_permission";
    case "ready":
    case "idle": return "idle";
    default: return "disconnected";
  }
}

const TITLE_FROM_PROMPT_LIMIT = 60;

/** One line, bounded: every title source goes through the same cut. */
function titleLabel(value) {
  if (typeof value !== "string") return null;
  const line = value.replace(/\s+/g, " ").trim();
  if (!line) return null;
  return line.length > TITLE_FROM_PROMPT_LIMIT ? `${line.slice(0, TITLE_FROM_PROMPT_LIMIT - 1)}…` : line;
}

/**
 * One naming rule for every provider: the CLI's own title when it has one
 * (Claude's ai-title), else the task a sub-agent was spawned with (Codex's
 * thread database), else the latest prompt, cut to a label. Never a raw id
 * or a scanner event name — the app falls back to "<provider> · <folder>".
 */
function sessionTitle(facts, events, raw) {
  const own = titleLabel(facts.title) ?? titleLabel(raw.task);
  if (own) return own;
  for (let index = (events?.length ?? 0) - 1; index >= 0; index -= 1) {
    if (events[index].kind === "turn_start" && events[index].title) return titleLabel(events[index].title);
  }
  return null;
}

/**
 * Warnings the app must show on a session. Codex edits inside its session
 * roots through its own tools without asking, so a read_only/ask Gateway
 * session is not edit-proof (Gateway 1.5.1 management contract); the same
 * holds for 1.4.0 daemons, which do not say so themselves.
 */
export function sessionAlerts(session) {
  const policy = session?.permissionPolicy;
  if (session?.provider !== "codex" || !policy || policy === "auto_approve") return [];
  return [{
    level: "warning",
    code: "permission_policy_partial",
    message: `${policy} 정책이 부분적으로만 적용됩니다. Codex는 세션 폴더 안의 파일을 권한 요청 없이 고칠 수 있습니다.`
  }];
}

// Placeholders the scanners use when they cannot see the real model.
const PLACEHOLDER_MODELS = new Set(["claude-cli", "grok-cli", "codex-cli"]);

function realModel(value) {
  return typeof value === "string" && value && !PLACEHOLDER_MODELS.has(value) ? value : null;
}

/**
 * The newer of the scanner's state and the timeline's. The scanner owns
 * liveness and approvals (a pending escalated exec); the timeline sees turn
 * boundaries the scanner cannot, e.g. a Grok turn that just ended.
 */
function resolvedStatus(raw, timeline) {
  const scanned = monitorStatus(raw.state);
  const hinted = timeline?.status;
  if (!hinted || scanned === "waiting_input" || scanned === "waiting_permission") return scanned;
  const scannedAt = Number(raw.time || 0) * 1_000;
  const hintedAt = Date.parse(timeline.statusAt ?? "");
  return Number.isFinite(hintedAt) && hintedAt > scannedAt ? hinted : scanned;
}

/**
 * The top of a session's parent chain. A chain that leaves the snapshot ends
 * at the missing parent's id; its provider is known only when the link came
 * with one (process lineage names it).
 */
function rootOf(session, byRawId) {
  let current = session;
  const visited = new Set([session.session]);
  while (current?.parent && !visited.has(current.parent)) {
    visited.add(current.parent);
    const parent = byRawId.get(current.parent);
    if (!parent) return { id: current.parent, provider: current.parent_provider ?? null };
    current = parent;
  }
  return { id: current?.session ?? session.session, provider: current?.provider ?? null };
}

/**
 * Scanner snapshot (+ per-session timelines from ./normalize/local-timeline.js)
 * -> canonical sessions and their events, keyed by monitor session id.
 * `timelines` maps `${provider}:${rawSessionId}` to `{ events, session }`.
 */
export function projectLocalSnapshot(snapshot, timelines = new Map()) {
  const allRawSessions = Array.isArray(snapshot?.sessions)
    ? snapshot.sessions.filter((session) => session?.session)
    : [];
  // Ancestry index over every raw session: a local grandchild can be spawned
  // through an intermediate the Gateway owns, and losing that link would
  // split the grandchild off as a false Frontdoor.
  const byRawId = new Map(allRawSessions.map((session) => [session.session, session]));
  const sessions = [];
  const events = {};

  for (const raw of allRawSessions) {
    const rootLink = rootOf(raw, byRawId);
    const rootId = rootLink.id;
    const root = byRawId.get(rootId);
    const provider = raw.provider ?? "local";
    const sessionId = `local:${provider}:${raw.session}`;
    const timeline = timelines.get(`${provider}:${raw.session}`) ?? null;
    const facts = timeline?.session ?? {};
    const scannedAt = isoTimestamp(raw.time);
    const status = resolvedStatus(raw, facts);
    const firstEventAt = timeline?.events?.[0]?.ts ?? null;
    const updatedAt = [scannedAt, facts.statusAt, timeline?.events?.at(-1)?.ts]
      .filter(Boolean)
      .reduce((latest, value) => (value > latest ? value : latest), scannedAt);
    const active = status === "running" || status === "waiting_input" || status === "waiting_permission";
    // A one-shot run (`claude -p`, `grok -p`, `codex exec`) is automation,
    // not a session a person opened: without a known launcher it is an
    // unattributed Worker, never a Frontdoor of its own. An SDK entrypoint
    // alone does not make one: a chat host that asks a person for permission,
    // or a conversation with more than one prompt, is someone talking to it.
    const conversed = (timeline?.events ?? []).filter((event) => event.kind === "user_message").length > 1;
    const headless = Boolean(raw.headless || facts.headless === true) && !raw.interactive && !conversed;
    const orphanRun = headless && raw.session === rootId && !raw.parent;

    sessions.push({
      sessionId,
      acpSessionId: raw.session,
      localSessionId: raw.session,
      provider,
      model: realModel(facts.model) ?? realModel(raw.engine),
      status,
      title: sessionTitle(facts, timeline?.events, raw),
      opener: root?.provider ?? rootLink.provider ?? raw.provider ?? "local",
      openerInstanceId: orphanRun ? null : rootId,
      cwd: raw.cwd ?? facts.cwd ?? root?.cwd ?? "",
      turnId: active ? facts.turnId ?? `local-turn:${raw.session}` : null,
      stopReason: status === "idle" ? "completed" : null,
      createdAt: firstEventAt && firstEventAt < scannedAt ? firstEventAt : scannedAt,
      updatedAt,
      eventCount: timeline?.events?.length ?? 0,
      usage: facts.usage ?? null,
      turnUsage: facts.turns ?? [],
      ...(facts.usagePartial ? { usagePartial: true } : {}),
      capabilities: localCapabilities(provider, timeline, raw.hooked === true),
      source: "local",
      role: raw.session === rootId && !orphanRun ? "frontdoor" : "worker",
      parentLocalSessionId: raw.parent ?? null,
      // Only name a local parent this snapshot can see, or one whose provider
      // the link itself proved (process lineage). Guessing it from the
      // child's minted ids like local:codex:<claude id> that point at
      // nothing; a Gateway-owned parent is resolved from parentLocalSessionId
      // by mergeMonitorSessions instead.
      parentSessionId: byRawId.has(raw.parent)
        ? `local:${byRawId.get(raw.parent).provider ?? "local"}:${raw.parent}`
        : raw.parent && raw.parent_provider ? `local:${raw.parent_provider}:${raw.parent}` : null,
      ...(raw.parent && raw.parent_source === "lineage" ? { parentProof: "lineage" } : {}),
      // A one-shot run (`claude -p`, `grok -p`, `codex exec`), so the app can
      // tell it from an interactive session.
      ...(headless ? { headless: true } : {})
    });
    if (timeline?.events?.length) events[sessionId] = timeline.events;
  }

  return { sessions, events };
}

/**
 * What this monitor can actually show for a local session, so the app can
 * tell "nothing happened" from "this source cannot see it".
 */
function localCapabilities(provider, timeline, hooked) {
  const capabilities = ["status"];
  if (timeline) capabilities.push("timeline", "tools", "usage", "thinking");
  // Codex writes approval waits into its rollout; Claude and Grok only
  // expose them through hooks.
  if (hooked || provider === "codex") capabilities.push("permission");
  if (hooked) capabilities.push("live");
  return capabilities;
}

/**
 * Which local timelines to hand to the event store on this pass: the ones
 * whose window changed, plus any accepted session not handed over since it
 * (re)appeared. Everything else is the same window the store already merged.
 */
export class LocalEventDelivery {
  constructor() {
    this.delivered = new Set();
  }

  /**
   * @param {Record<string, object[]>} events monitor session id -> window
   * @param {Set<string>} changedSessionIds sessions whose window changed
   * @param {Set<string>} acceptedIds local sessions the merge kept
   */
  select(events, changedSessionIds, acceptedIds) {
    const selected = {};
    for (const [sessionId, values] of Object.entries(events ?? {})) {
      if (!acceptedIds.has(sessionId)) continue;
      if (changedSessionIds.has(sessionId) || !this.delivered.has(sessionId)) selected[sessionId] = values;
    }
    // A session that leaves the local view is handed over again in full
    // when it returns (its store bucket may have expired meanwhile).
    this.delivered = new Set(Object.keys(events ?? {}).filter((sessionId) => acceptedIds.has(sessionId)));
    return selected;
  }
}

const MAX_CALLER_TOPOLOGY = 256;

/** Instance entries have no session to be pruned with; keep the newest. */
function pruneCallerTopology(workerTopology) {
  const keys = [...workerTopology.keys()].filter((key) => key.startsWith("caller:"));
  for (const key of keys.slice(0, Math.max(0, keys.length - MAX_CALLER_TOPOLOGY))) workerTopology.delete(key);
}

export function mergeMonitorSessions(gatewaySessions, localSessions, workerTopology = null, formerWorkerIds = null) {
  // ownedWorkerIds is LOAD-BEARING even though the scanner no longer produces
  // Gateway sessions itself: an ACP claude worker writes a transcript under
  // ~/.claude/projects like any other claude session, so the local scanner
  // detects it — this set is what stops it appearing twice.
  const gateway = Array.isArray(gatewaySessions) ? gatewaySessions : [];
  const gatewaySessionIdByProviderId = new Map(gateway.flatMap((session) => [
    [session?.sessionId, session?.sessionId],
    [session?.acpSessionId, session?.sessionId]
  ]).filter(([key, value]) => key && value));
  const localByProviderId = new Map((Array.isArray(localSessions) ? localSessions : [])
    .flatMap((session) => [
      [session?.localSessionId, session],
      [session?.sessionId, session]
    ])
    .filter(([key, value]) => key && value));
  const resolvedParentSessionId = (session) => gatewaySessionIdByProviderId.get(session?.parentLocalSessionId)
    ?? session?.parentSessionId
    ?? null;
  const localByMonitorId = new Map((Array.isArray(localSessions) ? localSessions : [])
    .filter((session) => session?.sessionId)
    .map((session) => [session.sessionId, session]));
  // Gateway 1.6 names the Main that opened a worker (`openedBy`). That is the
  // protocol's own record, so it beats any transcript reading. A Main that
  // exported its session id is its local session; the group is that
  // session's own group when the scan sees it.
  const callerTopology = (caller) => {
    if (!caller?.provider || !caller?.sessionId) return null;
    const parentSessionId = `local:${caller.provider}:${caller.sessionId}`;
    const parent = localByMonitorId.get(parentSessionId);
    return {
      opener: caller.provider,
      openerInstanceId: parent?.openerInstanceId ?? caller.sessionId,
      parentSessionId
    };
  };
  // Gateway 1.4 session records do not carry the Frontdoor topology fields.
  // The same provider transcript is already present in the local scan and has
  // those fields; preserve its topology on the authoritative Gateway record
  // before dropping the duplicate local record.
  //
  // Two invariants guard the Frontdoor sidebar here:
  // - A Gateway session is always opened by a Main, so its role is "worker"
  //   no matter what the transcript scan currently believes. An unlinked
  //   worker transcript roots to itself, and copying that self-rooted
  //   frontdoor identity used to promote every not-yet-linked worker to a
  //   false Frontdoor row of its own.
  // - Attribution is sticky. The transcript that proves a worker's parent
  //   goes stale seconds after the turn ends; `workerTopology` (owned by the
  //   caller, pruned on session removal) keeps the proven topology for the
  //   session's remaining lifetime instead of letting it evaporate.
  const enrichedGateway = gateway.map((session) => {
    const localMatch = localByProviderId.get(session?.acpSessionId)
      ?? localByProviderId.get(session?.sessionId);
    // Process lineage is not proof for a Gateway worker: the daemon may carry
    // whichever session's environment first started it. Only transcript
    // (MCP response) links attribute a Gateway session.
    const proven = localMatch?.openerInstanceId
      && localMatch.openerInstanceId !== localMatch.localSessionId
      && localMatch.parentProof !== "lineage"
      ? {
        opener: localMatch.opener ?? null,
        openerInstanceId: localMatch.openerInstanceId,
        parentSessionId: resolvedParentSessionId(localMatch)
      }
      : null;
    // Codex exports no thread id, only its control-server instance: once one
    // of that instance's workers is proven by transcript, the instance is
    // known, and every other worker it opened belongs to the same Main.
    const instanceKey = session?.openedBy?.instanceId ? `caller:${session.openedBy.instanceId}` : null;
    if (proven && instanceKey && workerTopology) {
      workerTopology.set(instanceKey, proven);
      pruneCallerTopology(workerTopology);
    }
    const byCaller = callerTopology(session?.openedBy)
      ?? proven
      ?? (instanceKey ? workerTopology?.get(instanceKey) : null)
      ?? null;
    if (byCaller && workerTopology && session?.sessionId) workerTopology.set(session.sessionId, byCaller);
    const topology = byCaller ?? workerTopology?.get(session?.sessionId) ?? null;
    return {
      ...session,
      role: session.role ?? "worker",
      // The Gateway keeps usage off its event stream; the worker's own
      // transcript (scanned locally) is where the tokens are.
      usage: session.usage ?? localMatch?.usage ?? null,
      turnUsage: session.turnUsage ?? localMatch?.turnUsage ?? [],
      model: session.model ?? localMatch?.model ?? null,
      capabilities: ["status", "timeline", "tools", "thinking", "permission", "live", ...(localMatch?.usage ? ["usage"] : [])],
      alerts: sessionAlerts(session),
      ...(topology ? {
        opener: session.opener ?? topology.opener,
        openerInstanceId: session.openerInstanceId ?? topology.openerInstanceId,
        parentSessionId: session.parentSessionId ?? topology.parentSessionId
      } : {})
    };
  });
  const ownedWorkerIds = new Set(gateway.flatMap((session) => [
    session?.sessionId,
    session?.acpSessionId
  ]).filter(Boolean));
  // A worker the Gateway already closed is history, not a new local root.
  const local = (Array.isArray(localSessions) ? localSessions : [])
    .filter((session) => !ownedWorkerIds.has(session.localSessionId) && !formerWorkerIds?.has(session.localSessionId))
    .map((session) => ({
      ...session,
      parentSessionId: resolvedParentSessionId(session)
    }));
  return [...enrichedGateway, ...local];
}
