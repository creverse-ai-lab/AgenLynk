// Durable monitor history in ~/.acp-gateway/agenlynk/monitor.db (node:sqlite).
//
// The sidecar owns this file; nothing else writes it. Writes are batched: the
// store hands over changed events synchronously and they are flushed in one
// transaction per interval, so a chunk flood costs one commit, not thousands.
// Any database failure disables persistence and the monitor keeps working
// from memory — history is a convenience, never a reason to go down.

import { chmodSync, mkdirSync, rmSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const MONITOR_DB_SCHEMA_VERSION = 1;
const DEFAULT_FLUSH_MS = 250;
const DEFAULT_RETENTION_DAYS = 14;
// Rows kept per session. Memory holds far fewer (the EventStore cap); this
// bounds what a session that stays live for weeks can pile up on disk.
const DEFAULT_MAX_EVENTS_PER_SESSION = 10_000;
const DATABASE_FILE_SUFFIXES = ["", "-wal", "-shm"];

/** Total size of a database and its WAL/SHM files, whether open or not. */
export function databaseFileBytes(path) {
  let bytes = 0;
  let exists = false;
  for (const suffix of DATABASE_FILE_SUFFIXES) {
    try {
      bytes += statSync(`${path}${suffix}`).size;
      exists = true;
    } catch {
      // Not present.
    }
  }
  return { exists, bytes };
}

/** Deletes a database and its WAL/SHM files. */
export function removeDatabaseFiles(path) {
  for (const suffix of DATABASE_FILE_SUFFIXES) rmSync(`${path}${suffix}`, { force: true });
}

export function defaultMonitorDatabasePath(env = process.env) {
  return env.ACP_GATEWAY_MONITOR_DB || join(homedir(), ".acp-gateway", "agenlynk", "monitor.db");
}

export class SqliteMonitorStore {
  /** Returns null (memory-only monitor) when node:sqlite or the file is unusable. */
  static async open(path, options = {}) {
    let DatabaseSync;
    try {
      ({ DatabaseSync } = await import("node:sqlite"));
    } catch {
      return null;
    }
    try {
      mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
      const database = new DatabaseSync(path);
      try {
        chmodSync(path, 0o600);
      } catch {
        // Best effort: an existing file keeps its mode.
      }
      return new SqliteMonitorStore(database, { ...options, path });
    } catch (error) {
      console.error(`Monitor history disabled: ${error.message}`);
      return null;
    }
  }

  constructor(database, {
    flushMs = DEFAULT_FLUSH_MS,
    retentionDays = DEFAULT_RETENTION_DAYS,
    maxEventsPerSession = DEFAULT_MAX_EVENTS_PER_SESSION,
    now = () => Date.now(),
    path = null
  } = {}) {
    this.database = database;
    this.path = path;
    this.flushMs = flushMs;
    this.retentionDays = retentionDays;
    this.maxEventsPerSession = maxEventsPerSession;
    this.now = now;
    this.pendingEvents = new Map();
    this.pendingSessions = new Map();
    this.timer = null;
    this.failed = false;
    this.#migrate();
  }

  #migrate() {
    this.database.exec("PRAGMA journal_mode = WAL");
    this.database.exec("PRAGMA synchronous = NORMAL");
    this.database.exec(`
      CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        provider TEXT,
        updated_at INTEGER NOT NULL,
        record TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS events (
        session_id TEXT NOT NULL,
        key TEXT NOT NULL,
        sequence INTEGER NOT NULL,
        ts INTEGER NOT NULL,
        record TEXT NOT NULL,
        PRIMARY KEY (session_id, key)
      );
      CREATE INDEX IF NOT EXISTS events_by_sequence ON events (session_id, sequence);
      CREATE INDEX IF NOT EXISTS sessions_by_update ON sessions (updated_at);
    `);
    this.database.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('schemaVersion', ?)")
      .run(String(MONITOR_DB_SCHEMA_VERSION));
    this.insertEvent = this.database.prepare(`
      INSERT INTO events (session_id, key, sequence, ts, record) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT (session_id, key) DO UPDATE SET sequence = excluded.sequence, ts = excluded.ts, record = excluded.record
    `);
    this.insertSession = this.database.prepare(`
      INSERT INTO sessions (session_id, provider, updated_at, record) VALUES (?, ?, ?, ?)
      ON CONFLICT (session_id) DO UPDATE SET provider = excluded.provider, updated_at = excluded.updated_at, record = excluded.record
    `);
  }

  writeEvents(sessionId, events) {
    if (this.failed) return;
    for (const event of events) this.pendingEvents.set(`${sessionId}\u0000${event.key}`, event);
    this.#schedule();
  }

  writeSession(session) {
    if (this.failed || !session?.sessionId) return;
    this.pendingSessions.set(session.sessionId, session);
    this.#schedule();
  }

  #schedule() {
    if (this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.flush();
    }, this.flushMs);
    this.timer.unref?.();
  }

  flush() {
    if (this.failed || (!this.pendingEvents.size && !this.pendingSessions.size)) return;
    const events = [...this.pendingEvents.values()];
    const sessions = [...this.pendingSessions.values()];
    this.pendingEvents.clear();
    this.pendingSessions.clear();
    try {
      this.database.exec("BEGIN");
      for (const event of events) {
        this.insertEvent.run(event.sessionId, event.key, event.sequence, Date.parse(event.ts) || 0, JSON.stringify(event));
      }
      for (const session of sessions) {
        const updatedAt = Date.parse(session.updatedAt ?? "") || this.now();
        this.insertSession.run(session.sessionId, session.provider ?? null, updatedAt, JSON.stringify(session));
      }
      this.database.exec("COMMIT");
    } catch (error) {
      try {
        this.database.exec("ROLLBACK");
      } catch {
        // No open transaction.
      }
      this.failed = true;
      console.error(`Monitor history disabled after a write failure: ${error.message}`);
    }
  }

  /**
   * Session records updated in [since, before) (ms), newest first. Paging a
   * history list passes the oldest `updatedAt` it has as the next `before`.
   */
  readSessions({ since = 0, before = Number.MAX_SAFE_INTEGER, beforeId = null, limit = 500 } = {}) {
    if (this.failed) return [];
    this.flush();
    const bound = Number.isFinite(before) ? before : Number.MAX_SAFE_INTEGER;
    // Keyset pagination on (updated_at, session_id): a page boundary inside a
    // run of equal timestamps continues with the next id instead of skipping.
    // Prepared once: restoring and paging call this many times in a row.
    this.selectSessions ??= this.database.prepare(`SELECT record FROM sessions
                 WHERE updated_at >= ? AND (updated_at < ? OR (updated_at = ? AND session_id < ?))
                 ORDER BY updated_at DESC, session_id DESC LIMIT ?`);
    return this.selectSessions
      .all(since, bound, bound, beforeId ?? "", limit)
      .map((row) => parse(row.record))
      .filter(Boolean);
  }

  /** Size and counts for the settings screen. */
  stats() {
    if (this.failed) return { available: false };
    this.flush();
    const count = (sql) => Number(this.database.prepare(sql).get()?.n ?? 0);
    return {
      available: true,
      path: this.path,
      bytes: databaseFileBytes(this.path).bytes,
      sessions: count("SELECT count(*) AS n FROM sessions"),
      events: count("SELECT count(*) AS n FROM events"),
      retentionDays: this.retentionDays
    };
  }

  /** Deletes all history except the sessions in `keep` (live ones). */
  clear({ keep = new Set() } = {}) {
    if (this.failed) return 0;
    this.flush();
    const ids = this.database.prepare("SELECT session_id FROM sessions").all()
      .map((row) => row.session_id)
      .filter((sessionId) => !keep.has(sessionId));
    const orphanEvents = this.database.prepare("SELECT DISTINCT session_id FROM events").all()
      .map((row) => row.session_id)
      .filter((sessionId) => !keep.has(sessionId));
    const all = [...new Set([...ids, ...orphanEvents])];
    try {
      this.database.exec("BEGIN");
      const deleteEvents = this.database.prepare("DELETE FROM events WHERE session_id = ?");
      const deleteSession = this.database.prepare("DELETE FROM sessions WHERE session_id = ?");
      for (const sessionId of all) {
        deleteEvents.run(sessionId);
        deleteSession.run(sessionId);
      }
      this.database.exec("COMMIT");
    } catch (error) {
      try {
        this.database.exec("ROLLBACK");
      } catch {
        // No open transaction.
      }
      console.error(`Monitor history clear failed: ${error.message}`);
      return 0;
    }
    // Reclaiming the space is a nicety: the deletion already committed, so a
    // failure here must not report it as not having happened.
    try {
      this.database.exec("VACUUM");
    } catch (error) {
      console.error(`Monitor history vacuum skipped: ${error.message}`);
    }
    return all.length;
  }

  /** The newest `limit` events with sequence < `before`, oldest first. */
  readEvents(sessionId, { before = Number.MAX_SAFE_INTEGER, limit = 200 } = {}) {
    if (this.failed) return [];
    const bound = Number.isFinite(before) ? before : Number.MAX_SAFE_INTEGER;
    this.selectEvents ??= this.database
      .prepare("SELECT record FROM events WHERE session_id = ? AND sequence < ? ORDER BY sequence DESC LIMIT ?");
    return this.selectEvents
      .all(sessionId, bound, limit)
      .map((row) => parse(row.record))
      .filter(Boolean)
      .reverse();
  }

  /**
   * Deletes sessions (and their events) not updated within the retention
   * window, except the ids in `keep` (live sessions); events whose session
   * has no row (and is not in `keep`); and, in every session, events beyond
   * the newest `maxEventsPerSession`. Returns the deleted session count.
   */
  prune({ keep = new Set(), retentionDays = this.retentionDays } = {}) {
    if (this.failed) return 0;
    this.flush();
    const cutoff = this.now() - retentionDays * 24 * 60 * 60 * 1000;
    const stale = this.database
      .prepare("SELECT session_id FROM sessions WHERE updated_at < ?")
      .all(cutoff)
      .map((row) => row.session_id)
      .filter((sessionId) => !keep.has(sessionId));
    const orphans = this.database
      .prepare("SELECT DISTINCT e.session_id FROM events e LEFT JOIN sessions s ON s.session_id = e.session_id WHERE s.session_id IS NULL")
      .all()
      .map((row) => row.session_id)
      .filter((sessionId) => !keep.has(sessionId));
    const oversized = this.database
      .prepare("SELECT session_id FROM events GROUP BY session_id HAVING count(*) > ?")
      .all(this.maxEventsPerSession)
      .map((row) => row.session_id);
    if (!stale.length && !orphans.length && !oversized.length) return 0;
    try {
      this.database.exec("BEGIN");
      const deleteEvents = this.database.prepare("DELETE FROM events WHERE session_id = ?");
      const deleteSession = this.database.prepare("DELETE FROM sessions WHERE session_id = ?");
      const trimEvents = this.database.prepare(`DELETE FROM events WHERE session_id = ? AND sequence < (
        SELECT sequence FROM events WHERE session_id = ? ORDER BY sequence DESC LIMIT 1 OFFSET ?
      )`);
      for (const sessionId of stale) {
        deleteEvents.run(sessionId);
        deleteSession.run(sessionId);
      }
      for (const sessionId of orphans) deleteEvents.run(sessionId);
      for (const sessionId of oversized) trimEvents.run(sessionId, sessionId, this.maxEventsPerSession - 1);
      this.database.exec("COMMIT");
    } catch (error) {
      try {
        this.database.exec("ROLLBACK");
      } catch {
        // No open transaction.
      }
      console.error(`Monitor history prune failed: ${error.message}`);
      return 0;
    }
    return stale.length;
  }

  close() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    this.flush();
    try {
      this.database.close();
    } catch {
      // Already closed.
    }
  }
}

function parse(text) {
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}
