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
    case "ready":
    case "idle": return "idle";
    default: return "disconnected";
  }
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
  if (!hinted || scanned === "waiting_input") return scanned;
  const scannedAt = Number(raw.time || 0) * 1_000;
  const hintedAt = Date.parse(timeline.statusAt ?? "");
  return Number.isFinite(hintedAt) && hintedAt > scannedAt ? hinted : scanned;
}

function rootSessionId(session, byRawId) {
  let current = session;
  const visited = new Set([session.session]);
  while (current?.parent && !visited.has(current.parent)) {
    visited.add(current.parent);
    const parent = byRawId.get(current.parent);
    if (!parent) return current.parent;
    current = parent;
  }
  return current?.session ?? session.session;
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
    const rootId = rootSessionId(raw, byRawId);
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

    sessions.push({
      sessionId,
      acpSessionId: raw.session,
      localSessionId: raw.session,
      provider,
      model: realModel(facts.model) ?? realModel(raw.engine),
      status,
      title: facts.title ?? raw.task ?? null,
      opener: root?.provider ?? raw.provider ?? "local",
      openerInstanceId: rootId,
      cwd: raw.cwd ?? facts.cwd ?? root?.cwd ?? "",
      turnId: active ? facts.turnId ?? `local-turn:${raw.session}` : null,
      stopReason: status === "idle" ? "completed" : null,
      createdAt: firstEventAt && firstEventAt < scannedAt ? firstEventAt : scannedAt,
      updatedAt,
      eventCount: timeline?.events?.length ?? 0,
      usage: facts.usage ?? null,
      ...(facts.usagePartial ? { usagePartial: true } : {}),
      capabilities: localCapabilities(provider, timeline),
      source: "local",
      role: raw.session === rootId ? "frontdoor" : "worker",
      parentLocalSessionId: raw.parent ?? null,
      // Only name a local parent this snapshot can see. Guessing its provider
      // from the child's minted ids like local:codex:<claude id> that point at
      // nothing; a Gateway-owned parent is resolved from parentLocalSessionId
      // by mergeMonitorSessions instead.
      parentSessionId: byRawId.has(raw.parent)
        ? `local:${byRawId.get(raw.parent).provider ?? "local"}:${raw.parent}`
        : null
    });
    if (timeline?.events?.length) events[sessionId] = timeline.events;
  }

  return { sessions, events };
}

/**
 * What this monitor can actually show for a local session, so the app can
 * tell "nothing happened" from "this source cannot see it".
 */
function localCapabilities(provider, timeline) {
  if (!timeline) return ["status"];
  const capabilities = ["status", "timeline", "tools", "usage"];
  if (provider === "claude" || provider === "codex" || provider === "grok") capabilities.push("thinking");
  // Codex writes approval waits into its rollout; Claude and Grok only
  // expose them through hooks.
  if (provider === "codex") capabilities.push("permission");
  return capabilities;
}

export function mergeMonitorSessions(gatewaySessions, localSessions, workerTopology = null) {
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
    const proven = localMatch?.openerInstanceId
      && localMatch.openerInstanceId !== localMatch.localSessionId
      ? {
        opener: localMatch.opener ?? null,
        openerInstanceId: localMatch.openerInstanceId,
        parentSessionId: resolvedParentSessionId(localMatch)
      }
      : null;
    if (proven && workerTopology && session?.sessionId) workerTopology.set(session.sessionId, proven);
    const topology = proven ?? workerTopology?.get(session?.sessionId) ?? null;
    return {
      ...session,
      role: session.role ?? "worker",
      // The Gateway keeps usage off its event stream; the worker's own
      // transcript (scanned locally) is where the tokens are.
      usage: session.usage ?? localMatch?.usage ?? null,
      model: session.model ?? localMatch?.model ?? null,
      capabilities: ["status", "timeline", "tools", "thinking", "permission", ...(localMatch?.usage ? ["usage"] : [])],
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
  const local = (Array.isArray(localSessions) ? localSessions : [])
    .filter((session) => !ownedWorkerIds.has(session.localSessionId))
    .map((session) => ({
      ...session,
      parentSessionId: resolvedParentSessionId(session)
    }));
  return [...enrichedGateway, ...local];
}
