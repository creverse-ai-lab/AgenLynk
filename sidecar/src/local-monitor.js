function isoTimestamp(value) {
  const seconds = Number(value);
  if (!Number.isFinite(seconds) || seconds <= 0) return new Date().toISOString();
  return new Date(seconds * 1_000).toISOString();
}

function monitorStatus(value) {
  switch (value) {
    case "running": return "running";
    case "needs_input": return "waiting_input";
    case "ready": return "ready";
    case "idle": return "idle";
    default: return "disconnected";
  }
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

export function projectLocalSnapshot(snapshot) {
  const allRawSessions = Array.isArray(snapshot?.sessions)
    ? snapshot.sessions.filter((session) => session?.session)
    : [];
  // Ancestry index over every raw session: a local grandchild can be spawned
  // through an intermediate the Gateway owns, and losing that link would
  // split the grandchild off as a false Frontdoor.
  const byRawId = new Map(allRawSessions.map((session) => [session.session, session]));
  const rawSessions = allRawSessions;
  const sessions = [];
  const events = {};

  for (const raw of rawSessions) {
    const rootId = rootSessionId(raw, byRawId);
    const root = byRawId.get(rootId);
    const provider = raw.provider ?? "local";
    const sessionId = `local:${provider}:${raw.session}`;
    const timestamp = isoTimestamp(raw.time);
    const role = raw.session === rootId ? "frontdoor" : "worker";
    const turnId = `local-turn:${raw.session}`;
    const title = raw.task || raw.event || `${raw.provider ?? "local"} local session`;
    const status = monitorStatus(raw.state);

    sessions.push({
      sessionId,
      acpSessionId: raw.session,
      localSessionId: raw.session,
      provider,
      model: raw.engine ?? null,
      status,
      title,
      opener: root?.provider ?? raw.provider ?? "local",
      openerInstanceId: rootId,
      cwd: raw.cwd ?? root?.cwd ?? "",
      turnId: ["running", "waiting_input"].includes(status) ? turnId : null,
      stopReason: status === "ready" ? "completed" : null,
      createdAt: timestamp,
      updatedAt: timestamp,
      eventCount: status === "ready" ? 2 : 1,
      source: "local",
      role,
      parentLocalSessionId: raw.parent ?? null,
      parentSessionId: raw.parent ? `local:${byRawId.get(raw.parent)?.provider ?? provider}:${raw.parent}` : null
    });

    const baseSequence = Math.max(0, Math.floor(Number(raw.time || 0) * 1_000) * 2);
    const projected = [{
      sessionId,
      sequence: baseSequence,
      type: "turn_start",
      ts: timestamp,
      turnId,
      text: title,
      source: "local"
    }];
    if (status === "ready" || status === "idle" || status === "disconnected") {
      projected.push({
        sessionId,
        sequence: baseSequence + 1,
        type: status === "disconnected" ? "error" : "turn_end",
        ts: timestamp,
        turnId,
        stopReason: status,
        source: "local"
      });
    }
    events[sessionId] = projected;
  }

  return { sessions, events };
}

export function mergeMonitorSessions(gatewaySessions, localSessions) {
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
  const enrichedGateway = gateway.map((session) => {
    const localMatch = localByProviderId.get(session?.acpSessionId)
      ?? localByProviderId.get(session?.sessionId);
    if (!localMatch) return session;
    return {
      ...session,
      opener: session.opener ?? localMatch.opener,
      openerInstanceId: session.openerInstanceId ?? localMatch.openerInstanceId,
      role: session.role ?? localMatch.role,
      parentSessionId: session.parentSessionId ?? resolvedParentSessionId(localMatch)
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
