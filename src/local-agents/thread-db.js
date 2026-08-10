// Codex's own thread database (~/.codex/state_5.sqlite).
//
// This is where local sub-agents become visible: `threads.thread_source` is
// "subagent" for a thread Codex spawned, and `thread_spawn_edges` carries the
// real parent -> child graph. Neither fact exists anywhere in the rollout
// transcripts, so the JSONL scan alone cannot reconstruct the tree.

import { selectAll, withReadOnlyDatabase } from "./sqlite.js";

/**
 * Looks up the given thread ids in one database.
 * Returns engines/workdirs/subagents/parents keyed by thread id.
 */
export async function readThreadFacts(databasePath, threadIds) {
  const ids = [...new Set(threadIds)].filter((id) => typeof id === "string" && id.length > 0);
  const empty = { engines: new Map(), workdirs: new Map(), subagents: new Set(), parents: new Map() };
  if (!ids.length) return empty;

  return withReadOnlyDatabase(databasePath, (database) => {
    const placeholders = ids.map(() => "?").join(",");
    const edges = selectAll(
      database,
      `SELECT child_thread_id, parent_thread_id FROM thread_spawn_edges WHERE child_thread_id IN (${placeholders})`,
      ids
    );
    const threads = selectAll(
      database,
      `SELECT id, COALESCE(model, model_provider) AS engine, cwd, thread_source FROM threads WHERE id IN (${placeholders})`,
      ids
    );
    const engines = new Map();
    const workdirs = new Map();
    const subagents = new Set();
    const parents = new Map();
    for (const row of edges) {
      if (row?.child_thread_id) parents.set(row.child_thread_id, row.parent_thread_id ?? null);
    }
    for (const row of threads) {
      if (!row?.id) continue;
      if (row.engine != null) engines.set(row.id, row.engine);
      if (row.cwd != null) workdirs.set(row.id, row.cwd);
      if (row.thread_source === "subagent") subagents.add(row.id);
    }
    return { engines, workdirs, subagents, parents };
  }, empty);
}

/**
 * Recently touched Codex threads and the rollout transcript each one writes.
 * Used instead of walking ~/.codex/sessions: the database already knows every
 * live thread's exact transcript path, so discovery costs one query rather
 * than a recursive directory scan.
 */
export async function readRecentThreads(databasePath, { since = 0, limit = 200 } = {}) {
  return withReadOnlyDatabase(databasePath, (database) => selectAll(
    database,
    `SELECT id, rollout_path, COALESCE(model, model_provider) AS engine, cwd, thread_source, updated_at
       FROM threads
      WHERE updated_at >= ?
      ORDER BY updated_at DESC
      LIMIT ?`,
    [Math.floor(since), limit]
  ).filter((row) => typeof row?.id === "string" && typeof row?.rollout_path === "string"), []);
}
