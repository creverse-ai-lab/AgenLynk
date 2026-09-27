// Codex's own thread database (~/.codex/state_5.sqlite).
//
// This is where local sub-agents become visible: `threads.thread_source` is
// "subagent" for a thread Codex spawned, and `thread_spawn_edges` carries the
// real parent -> child graph. Neither fact exists anywhere in the rollout
// transcripts, so the JSONL scan alone cannot reconstruct the tree.

import { selectAll, withReadOnlyDatabase } from "./sqlite.js";

// The scanner calls readThreadFacts every second with a usually-unchanged id
// set. Thread rows (engine, cwd, spawn edges) change rarely, so a short TTL
// spares an sqlite open per second. TTL rather than db-file mtime: the
// database is WAL, where writes land in the -wal file and the main file's
// mtime only moves at checkpoints — mtime would serve stale facts for far
// longer than this does.
const FACTS_TTL_MS = 5_000;
const factsCache = new Map();

/**
 * Looks up the given thread ids in one database.
 * Returns engines/workdirs/subagents/parents keyed by thread id.
 */
export async function readThreadFacts(databasePath, threadIds) {
  const ids = [...new Set(threadIds)].filter((id) => typeof id === "string" && id.length > 0);
  const empty = { engines: new Map(), workdirs: new Map(), subagents: new Set(), parents: new Map(), headless: new Set() };
  if (!ids.length) return empty;

  const cacheKey = `${databasePath}\u0000${[...ids].sort().join(",")}`;
  const cached = factsCache.get(cacheKey);
  if (cached && Date.now() - cached.at < FACTS_TTL_MS) return cached.facts;

  const facts = await withReadOnlyDatabase(databasePath, (database) => {
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
    // `codex exec` threads: a separate query, since older databases have no
    // `source` column and must not lose the facts above.
    const headless = new Set(selectAll(
      database,
      `SELECT id FROM threads WHERE source = 'exec' AND id IN (${placeholders})`,
      ids
    ).map((row) => row?.id).filter(Boolean));
    for (const row of edges) {
      if (row?.child_thread_id) parents.set(row.child_thread_id, row.parent_thread_id ?? null);
    }
    for (const row of threads) {
      if (!row?.id) continue;
      if (row.engine != null) engines.set(row.id, row.engine);
      if (row.cwd != null) workdirs.set(row.id, row.cwd);
      if (row.thread_source === "subagent") subagents.add(row.id);
    }
    return { engines, workdirs, subagents, parents, headless };
  }, empty);

  // Cache misses as well as hits: a missing database costs a stat per call too.
  factsCache.set(cacheKey, { at: Date.now(), facts });
  // Different id sets create different keys; drop expired ones so the cache
  // cannot grow without bound across changing session populations.
  if (factsCache.size > 64) {
    for (const [key, entry] of factsCache) {
      if (Date.now() - entry.at >= FACTS_TTL_MS) factsCache.delete(key);
    }
  }
  return facts;
}

/**
 * Recently touched Codex threads and the rollout transcript each one writes.
 * Used instead of walking ~/.codex/sessions: the database already knows every
 * live thread's exact transcript path, so discovery costs one query rather
 * than a recursive directory scan.
 *
 * Returns null when the database itself is unavailable — the caller falls
 * back to walking then. An EMPTY result is returned as [], and must NOT
 * trigger the walk: "no recent threads" is the answer, and treating it as a
 * failure made the scanner walk the full sessions tree every discovery pass
 * precisely when the machine was idle.
 */
export async function readRecentThreads(databasePath, { since = 0, limit = 200 } = {}) {
  return withReadOnlyDatabase(databasePath, (database) => {
    const rows = selectAll(
      database,
      `SELECT id, rollout_path, COALESCE(model, model_provider) AS engine, cwd, thread_source, updated_at
         FROM threads
        WHERE updated_at >= ?
        ORDER BY updated_at DESC
        LIMIT ?`,
      [Math.floor(since), limit]
    ).filter((row) => typeof row?.id === "string" && typeof row?.rollout_path === "string");
    if (!rows.length) return rows;
    // `codex exec` threads and when they started (for process lineage). A
    // separate query: older databases lack `source`/`created_at`, and must
    // not lose discovery itself.
    const exec = new Map(selectAll(
      database,
      `SELECT id, created_at FROM threads WHERE source = 'exec' AND updated_at >= ?`,
      [Math.floor(since)]
    ).map((row) => [row?.id, Number(row?.created_at)]));
    for (const row of rows) {
      const createdAt = exec.get(row.id);
      if (Number.isFinite(createdAt) && createdAt > 0) row.exec_created_at = createdAt;
    }
    return rows;
  }, null);
}
