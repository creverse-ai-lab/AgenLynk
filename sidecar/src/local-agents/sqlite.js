// Thin adapter over node:sqlite.
//
// node:sqlite is still flagged experimental in Node 22 (it works without a
// flag, but emits ExperimentalWarning and its API may shift). Every read goes
// through here so a future API change is a one-file edit, and so callers never
// have to care that the module might be missing entirely.
//
// This only ever READS databases owned by other tools (Codex's state_5.sqlite).
// The Gateway's own persistence stays JSON.

let databaseConstructor;
let loadAttempted = false;

async function loadDatabaseSync() {
  if (loadAttempted) return databaseConstructor;
  loadAttempted = true;
  try {
    ({ DatabaseSync: databaseConstructor } = await import("node:sqlite"));
  } catch {
    databaseConstructor = null;
  }
  return databaseConstructor;
}

/**
 * Runs `reader` against a read-only connection and always closes it. Returns
 * `fallback` when sqlite is unavailable, the file is missing, or any query
 * fails — a local-monitoring nicety must never take the monitor down.
 */
export async function withReadOnlyDatabase(path, reader, fallback) {
  const DatabaseSync = await loadDatabaseSync();
  if (!DatabaseSync || !path) return fallback;
  let database;
  try {
    database = new DatabaseSync(path, { readOnly: true });
    return reader(database);
  } catch {
    return fallback;
  } finally {
    try {
      database?.close();
    } catch {
      // A connection that failed to open has nothing to close.
    }
  }
}

/** `SELECT` helper that returns [] instead of throwing on a malformed schema. */
export function selectAll(database, sql, parameters = []) {
  try {
    return database.prepare(sql).all(...parameters);
  } catch {
    return [];
  }
}
