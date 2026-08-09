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
  // Gateway-owned records are not displayed twice, but they must remain in
  // the ancestry index. A local grandchild can be spawned by an ACP worker;
  // dropping that intermediate record would split it into a false Frontdoor.
  const byRawId = new Map(allRawSessions.map((session) => [session.session, session]));
  const rawSessions = allRawSessions.filter((session) => session.delegated !== true);
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
  const gateway = Array.isArray(gatewaySessions) ? gatewaySessions : [];
  const gatewaySessionIdByProviderId = new Map(gateway.flatMap((session) => [
    [session?.sessionId, session?.sessionId],
    [session?.acpSessionId, session?.sessionId]
  ]).filter(([key, value]) => key && value));
  const ownedWorkerIds = new Set(gateway.flatMap((session) => [
    session?.sessionId,
    session?.acpSessionId
  ]).filter(Boolean));
  const local = (Array.isArray(localSessions) ? localSessions : [])
    .filter((session) => !ownedWorkerIds.has(session.localSessionId))
    .map((session) => ({
      ...session,
      parentSessionId: gatewaySessionIdByProviderId.get(session.parentLocalSessionId)
        ?? session.parentSessionId
    }));
  return [...gateway, ...local];
}
