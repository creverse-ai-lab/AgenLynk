// Codex rollout transcripts, tailed incrementally.
//
// Discovery comes from Codex's thread database when it is available: `threads`
// already stores every live thread's exact `rollout_path`, so one query
// replaces a recursive walk of ~/.codex/sessions. A directory scan remains as
// the fallback for Orca account homes and for a missing/unreadable database.

import { open, readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { isConversationRecord } from "../local-transcript.js";
import { readRecord } from "./jsonl.js";
import { recordExternalParent } from "./parent-links.js";
import { signalWithApprovals } from "./signals.js";
import { stateRecord } from "./snapshot.js";
import { readRecentThreads } from "./thread-db.js";

// The tail is read once and feeds TWO consumers: the state reducer (signals/
// approvals) and the per-session conversation window the event projection
// reads. Before this, LocalTranscriptReader re-read the very same appended
// bytes every second with its own cursor, cache and rewrite detection — two
// copies of the scanner's most fragile logic over its hottest file.
const CONVERSATION_WINDOW_MS = 65 * 60 * 1000;
const MAX_CONVERSATION_RECORDS = 4_000;
// A transcript adopted mid-life is read from its tail, not from byte zero: an
// old rollout can be arbitrarily large, and state/events both only need the
// recent window anyway.
const ADOPTION_TAIL_BYTES = 12 * 1024 * 1024;

function newCursor(session, modified, database) {
  return {
    offset: 0,
    session,
    seen: modified,
    // mtime observed at the last successful read, so a same-sized atomic
    // rewrite (invisible to the size check) still resets the cursor.
    lastMtimeMs: 0,
    identified: false,
    database: database ?? null,
    pendingApprovals: new Set(),
    // Conversation-shaped records from the tail, bounded by time and count,
    // consumed by the event projection.
    conversation: []
  };
}

function pruneConversation(cursor, nowMs) {
  const cutoff = nowMs - CONVERSATION_WINDOW_MS;
  let drop = 0;
  while (drop < cursor.conversation.length) {
    const at = Date.parse(cursor.conversation[drop].timestamp ?? "");
    if (Number.isFinite(at) && at >= cutoff) break;
    drop += 1;
  }
  if (cursor.conversation.length - drop > MAX_CONVERSATION_RECORDS) {
    drop = cursor.conversation.length - MAX_CONVERSATION_RECORDS;
  }
  if (drop > 0) cursor.conversation.splice(0, drop);
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
  // knownModified: recency already known from the thread database, so those
  // candidates cost zero syscalls to consider — discovery runs every 2s, and
  // a stat per candidate was pure duplication of what the DB just reported.
  const consider = async (path, knownModified = null) => {
    let modified = knownModified;
    if (modified == null) {
      try {
        modified = (await stat(path)).mtimeMs / 1000;
      } catch {
        return;
      }
    }
    // Retirement holds until the file is newer than when it was retired. The
    // 1s tolerance matters: the DB reports whole seconds while stat reports
    // sub-second mtimes, and an exact-equality check across the two sources
    // would un-retire (and fully re-read) every retired transcript each pass.
    const retiredAt = retired.get(path);
    if (retiredAt != null && modified <= retiredAt + 1) return;
    if (cursors.has(path)) return;
    if (explicitPaths.length || now - modified <= staleAfter) {
      // The DB's updated_at can lag the file slightly; poll() stats the real
      // file before reading, so a coarse recency signal is all that's needed.
      retired.delete(path);
      cursors.set(path, newCursor(transcriptStem(path), modified, database));
    }
  };

  if (explicitPaths.length) {
    for (const path of explicitPaths) await consider(path);
    return;
  }
  const threads = await readRecentThreads(database, { since: now - staleAfter });
  if (threads !== null) {
    // The database answered — possibly "nothing recent", which is complete
    // information, not a reason to fall back to walking the whole tree.
    for (const thread of threads) {
      await consider(thread.rollout_path, Number(thread.updated_at) || null);
    }
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
    // A shrunken file was rotated or rewritten: start over. A file whose size
    // matches the cursor but whose mtime moved was atomically replaced with
    // same-sized content — equally a rewrite, and invisible to the size check.
    if (metadata.size < cursor.offset
      || (metadata.size === cursor.offset && cursor.offset > 0 && metadata.mtimeMs !== cursor.lastMtimeMs)) {
      cursor.offset = 0;
      cursor.identified = false;
      cursor.pendingApprovals.clear();
      cursor.conversation = [];
    }
    if (metadata.size === cursor.offset) {
      cursor.seen = modified;
      continue;
    }

    const initial = cursor.offset === 0;
    // Adoption of a large existing transcript starts from its tail: the whole
    // file could be hundreds of MB, and both consumers only need the recent
    // window. Skipping to just past the first newline keeps line integrity.
    if (initial && metadata.size > ADOPTION_TAIL_BYTES) {
      cursor.offset = metadata.size - ADOPTION_TAIL_BYTES;
    }
    let latest = null;
    let handle;
    try {
      handle = await open(path, "r");
      const length = metadata.size - cursor.offset;
      const buffer = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buffer, 0, length, cursor.offset);
      // A tail-adopted read starts mid-line; drop everything up to (and
      // including) the first newline so parsing begins on a line boundary.
      let skip = 0;
      if (initial && cursor.offset > 0) {
        const firstNewline = buffer.indexOf(0x0A);
        skip = firstNewline >= 0 ? firstNewline + 1 : bytesRead;
      }
      const view = buffer.subarray(skip, bytesRead);
      // Advance in BYTES, found on the raw buffer. Decoding first and using a
      // string index would undercount whenever the tail holds multibyte text
      // (routine in these transcripts), leaving the cursor short and re-reading
      // — and re-signalling — the same records on every poll forever.
      const lastNewline = view.lastIndexOf(0x0A);
      const consumed = lastNewline >= 0 ? lastNewline + 1 : 0;
      // Only advance past complete lines; a transcript the agent is still
      // writing must be re-read from the start of its partial last line.
      const text = view.subarray(0, consumed).toString("utf8");
      for (const line of text.split("\n")) {
        if (!line) continue;
        const record = readRecord(line);
        if (!record || typeof record !== "object") continue;
        if (record.type === "session_meta" && !cursor.identified) {
          cursor.session = record?.payload?.id || cursor.session;
          cursor.identified = true;
        }
        if (recordExternalParent(record, cursor.session, parents, now)) changed = true;
        // Second consumer of the same read: conversation-shaped records feed
        // the event projection so nothing re-reads this file for events.
        if (isConversationRecord(record)) cursor.conversation.push(record);
        const signal = signalWithApprovals(record, cursor.pendingApprovals);
        if (signal) {
          latest = stateRecord(cursor.session, signal[0], signal[1], modified, cursor.database);
          states[cursor.session] = latest;
          changed = true;
        }
      }
      pruneConversation(cursor, now * 1000);
      cursor.offset += skip + consumed;
      cursor.lastMtimeMs = metadata.mtimeMs;
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
