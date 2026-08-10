// Codex rollout transcripts, tailed incrementally.
//
// Discovery comes from Codex's thread database when it is available: `threads`
// already stores every live thread's exact `rollout_path`, so one query
// replaces a recursive walk of ~/.codex/sessions. A directory scan remains as
// the fallback for Orca account homes and for a missing/unreadable database.

import { open, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { readRecord } from "./jsonl.js";
import { recordExternalParent } from "./parent-links.js";
import { signalWithApprovals } from "./signals.js";
import { stateRecord } from "./snapshot.js";
import { readRecentThreads } from "./thread-db.js";

function newCursor(session, modified, database) {
  return {
    offset: 0,
    session,
    seen: modified,
    identified: false,
    database: database ?? null,
    pendingApprovals: new Set()
  };
}

function transcriptStem(path) {
  return path.split("/").pop().replace(/\.jsonl$/, "");
}

async function* rolloutPaths(root) {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      yield* rolloutPaths(path);
    } else if (entry.isFile() && entry.name.startsWith("rollout-") && entry.name.endsWith(".jsonl")) {
      yield path;
    }
  }
}

/**
 * Adds cursors for transcripts worth following. `retired` remembers files this
 * scanner gave up on, keyed by the mtime it saw, so a retired file is only
 * reconsidered once it actually changes.
 */
export async function discover({ root, explicitPaths = [], cursors, retired, staleAfter, now, database = null }) {
  let paths;
  if (explicitPaths.length) {
    paths = explicitPaths;
  } else {
    const threads = await readRecentThreads(database, { since: now - staleAfter });
    paths = threads.length ? threads.map((thread) => thread.rollout_path) : null;
  }

  const consider = async (path) => {
    let modified;
    try {
      modified = (await stat(path)).mtimeMs / 1000;
    } catch {
      return;
    }
    if (retired.get(path) === modified) return;
    retired.delete(path);
    if (cursors.has(path) || explicitPaths.length || now - modified <= staleAfter) {
      if (!cursors.has(path)) cursors.set(path, newCursor(transcriptStem(path), modified, database));
    }
  };

  if (paths) {
    for (const path of paths) await consider(path);
    return;
  }
  for await (const path of rolloutPaths(root)) await consider(path);
}

/** Reads everything appended since the last poll and updates `states`. */
export async function poll({ cursors, states, parents, now }) {
  let changed = false;
  for (const [path, cursor] of [...cursors]) {
    let metadata;
    try {
      metadata = await stat(path);
    } catch {
      cursors.delete(path);
      if (states[cursor.session]) {
        delete states[cursor.session];
        changed = true;
      }
      continue;
    }
    const modified = metadata.mtimeMs / 1000;
    // A shrunken file was rotated or rewritten: start over.
    if (metadata.size < cursor.offset) {
      cursor.offset = 0;
      cursor.identified = false;
      cursor.pendingApprovals.clear();
    }
    if (metadata.size === cursor.offset) {
      cursor.seen = modified;
      continue;
    }

    const initial = cursor.offset === 0;
    let latest = null;
    let handle;
    try {
      handle = await open(path, "r");
      const length = metadata.size - cursor.offset;
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, cursor.offset);
      const text = buffer.toString("utf8");
      // Only advance past complete lines; a transcript the agent is still
      // writing must be re-read from the start of its partial last line.
      const lastNewline = text.lastIndexOf("\n");
      const consumed = lastNewline >= 0 ? lastNewline + 1 : 0;
      for (const line of text.slice(0, consumed).split("\n")) {
        if (!line) continue;
        const record = readRecord(line);
        if (!record || typeof record !== "object") continue;
        if (record.type === "session_meta" && !cursor.identified) {
          cursor.session = record?.payload?.id || cursor.session;
          cursor.identified = true;
        }
        if (recordExternalParent(record, cursor.session, parents, now)) changed = true;
        const signal = signalWithApprovals(record, cursor.pendingApprovals);
        if (signal) {
          latest = stateRecord(cursor.session, signal[0], signal[1], modified, cursor.database);
          states[cursor.session] = latest;
          changed = true;
        }
      }
      cursor.offset += consumed;
      cursor.seen = modified;
    } catch {
      cursors.delete(path);
      if (states[cursor.session]) {
        delete states[cursor.session];
        changed = true;
      }
      continue;
    } finally {
      await handle?.close().catch(() => {});
    }

    // A transcript picked up mid-life still needs to appear, even when the
    // tail carried no signal at all.
    if (initial) {
      latest = latest ?? stateRecord(cursor.session, "idle", "session/open", modified, cursor.database);
      states[cursor.session] = latest;
      changed = true;
    }
  }
  return changed;
}

/** Retires cursors whose transcript has gone quiet for longer than its lifetime. */
export function prune({ cursors, states, retired, readyAfter, staleAfter, now }) {
  let changed = false;
  for (const [path, cursor] of [...cursors]) {
    const state = states[cursor.session];
    const lifetime = state && state.state === "ready" ? readyAfter : staleAfter;
    if (now - cursor.seen <= lifetime) continue;
    cursors.delete(path);
    retired.set(path, cursor.seen);
    if (states[cursor.session]) {
      delete states[cursor.session];
      changed = true;
    }
  }
  for (const [path, modified] of [...retired]) {
    if (now - modified > staleAfter) retired.delete(path);
  }
  return changed;
}
