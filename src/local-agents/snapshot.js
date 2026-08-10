// Assembles the flat session list every consumer sees, resolving parenthood.
//
// Ported from codex_app_watcher.py's snapshot_sessions. Three passes matter:
//   1. rewrite link ids (a worker is linked by its provider-side id, but the
//      snapshot exposes a different id for the session that owns it),
//   2. fold in Codex's thread database (engine, cwd, spawn edges, sub-agents),
//   3. a same-cwd fallback for sub-agents Codex spawned without an edge —
//      cycle-checked, so an orchestrator is never re-parented under its own
//      worker.

import { readThreadFacts } from "./thread-db.js";

export function stateRecord(session, state, event, timestamp, database = null) {
  const record = {
    provider: "codex",
    session,
    state,
    event,
    time: timestamp,
    pid: null
  };
  if (database) record._database = String(database);
  return record;
}

export async function snapshotSessions(states, database = null) {
  const sessions = Object.values(states).map((item) => ({ ...item }));

  // 1) Links are recorded against a session's provider-side id; resolve those
  // to the id this snapshot actually exposes.
  const byLink = new Map(sessions.map((item) => [item.link_session ?? item.session, item.session]));
  const known = new Set(sessions.map((item) => item.session));
  for (const item of sessions) {
    const parent = item.parent;
    if (parent && !known.has(parent) && byLink.has(parent)) item.parent = byLink.get(parent);
  }

  // 2) Group Codex sessions by the database that owns them. Orca accounts each
  // carry their own state_5.sqlite, so this is not always a single file.
  const idsByDatabase = new Map();
  for (const item of sessions) {
    const sourceDatabase = item._database ?? null;
    delete item._database;
    const target = sourceDatabase ?? database;
    if (item.provider !== "codex" || !target) continue;
    const key = String(target);
    if (!idsByDatabase.has(key)) idsByDatabase.set(key, []);
    idsByDatabase.get(key).push(item.session);
  }

  const engines = new Map();
  const workdirs = new Map();
  const subagents = new Set();
  const spawnParents = new Map();
  for (const [databasePath, ids] of idsByDatabase) {
    const facts = await readThreadFacts(databasePath, ids);
    for (const [id, value] of facts.engines) engines.set(id, value);
    for (const [id, value] of facts.workdirs) workdirs.set(id, value);
    for (const id of facts.subagents) subagents.add(id);
    for (const [id, value] of facts.parents) spawnParents.set(id, value);
  }

  // Codex's auto-review threads are machinery, not work someone started, so
  // they never adopt other sessions.
  const activeByCwd = new Map();
  for (const item of sessions) {
    if (item.provider !== "codex") continue;
    if (item.state !== "running" && item.state !== "needs_input") continue;
    if (engines.get(item.session) === "codex-auto-review") continue;
    const cwd = workdirs.get(item.session);
    if (!cwd) continue;
    if (!activeByCwd.has(cwd)) activeByCwd.set(cwd, []);
    activeByCwd.get(cwd).push(item);
  }

  for (const item of sessions) {
    if (item.provider !== "codex") continue;
    item.parent = item.parent || spawnParents.get(item.session) || null;
    item.engine = engines.get(item.session) || item.engine;
    const cwd = workdirs.get(item.session);
    if (cwd) item.cwd = cwd;
  }

  // 3) Same-cwd fallback, cycle-checked.
  const parentOf = new Map(sessions.map((item) => [item.session, item.parent ?? null]));
  const createsCycle = (child, candidate) => {
    const visited = new Set();
    let current = candidate;
    while (current != null && !visited.has(current)) {
      if (current === child) return true;
      visited.add(current);
      current = parentOf.get(current) ?? null;
    }
    return false;
  };

  for (const item of sessions) {
    // Only processes Codex plausibly spawned. Interactive Claude Code sessions
    // (claude-cli) and gateway-owned sessions (delegated — linked via their
    // real owner) are roots of their own.
    const eligible = !item.parent
      && item.delegated !== true
      && item.engine !== "claude-cli"
      && (item.provider !== "codex" || subagents.has(item.session));
    if (eligible) {
      const cwd = item.provider === "codex" ? workdirs.get(item.session) : item.cwd;
      const candidates = cwd
        ? (activeByCwd.get(cwd) ?? []).filter((candidate) =>
            candidate.session !== item.session && !createsCycle(item.session, candidate.session))
        : [];
      if (candidates.length) {
        const newest = candidates.reduce((best, candidate) =>
          (candidate.time ?? 0) > (best.time ?? 0) ? candidate : best);
        item.parent = newest.session;
        parentOf.set(item.session, item.parent);
      }
    }
    if (!item.cwd) delete item.cwd;
    delete item.link_session;
  }
  return sessions;
}
