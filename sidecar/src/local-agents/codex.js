// Codex rollout transcripts, tailed incrementally.
//
// Discovery comes from Codex's thread database when it is available: `threads`
// already stores every live thread's exact `rollout_path`, so one query
// replaces a recursive walk of ~/.codex/sessions. Production discovery stays
// database-only: if the database is unavailable, privacy wins over exhaustive
// detection and the scanner does not walk the whole transcript tree.

import { open, readdir, stat } from "node:fs/promises";
import { basename, join } from "node:path";
import { isWithin } from "../app/fs-paths.js";
import { isCodexTimelineRecord } from "../normalize/codex.js";
import { epochMs } from "../normalize/model.js";
import { readRecord, recordSize, slimRecord } from "./jsonl.js";
import { recordExternalParent } from "./parent-links.js";
import { signalWithApprovals } from "./signals.js";
import { stateRecord } from "./snapshot.js";
import { DEFAULT_MAX_WINDOW_CHARS, MAX_READ_BYTES } from "./tail.js";
import { readRecentThreads } from "./thread-db.js";

// The tail is read once and feeds TWO consumers: the state reducer (signals/
// approvals) and the per-session conversation window the event projection
// reads. Before this, LocalTranscriptReader re-read the very same appended
// bytes every second with its own cursor, cache and rewrite detection — two
// copies of the scanner's most fragile logic over its hottest file.
const DEFAULT_CONVERSATION_WINDOW_MS = 65 * 60 * 1000;
const DEFAULT_MAX_CONVERSATION_RECORDS = 4_000;
// A transcript adopted mid-life is read from its tail, not from byte zero: an
// old rollout can be arbitrarily large, and state/events both only need the
// recent window anyway.
const ADOPTION_TAIL_BYTES = 12 * 1024 * 1024;

function newCursor(session, modified, database, {
  conversationWindowMs = DEFAULT_CONVERSATION_WINDOW_MS,
  maxConversationRecords = DEFAULT_MAX_CONVERSATION_RECORDS
} = {}) {
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
    conversation: [],
    // Retained size per conversation record (parallel) and their sum.
    conversationSizes: [],
    conversationChars: 0,
    conversationWindowMs,
    maxConversationRecords
  };
}

function pruneConversation(cursor, nowMs) {
  const cutoff = nowMs - cursor.conversationWindowMs;
  let drop = 0;
  while (drop < cursor.conversation.length) {
    const at = epochMs(cursor.conversation[drop].timestamp);
    if (at != null && at >= cutoff) break;
    drop += 1;
  }
  if (cursor.conversation.length - drop > cursor.maxConversationRecords) {
    drop = cursor.conversation.length - cursor.maxConversationRecords;
  }
  let chars = cursor.conversationChars;
  for (let index = 0; index < drop; index += 1) chars -= cursor.conversationSizes[index];
  while (chars > DEFAULT_MAX_WINDOW_CHARS && drop < cursor.conversation.length - 1) {
    chars -= cursor.conversationSizes[drop];
    drop += 1;
  }
  if (drop > 0) {
    cursor.conversation.splice(0, drop);
    cursor.conversationSizes.splice(0, drop);
    cursor.conversationChars = chars;
  }
}

function resetConversation(cursor) {
  cursor.conversation = [];
  cursor.conversationSizes = [];
  cursor.conversationChars = 0;
}

// Bookkeeping records carry large payloads (base instructions, the whole
// compacted history) the normalizer never reads; only these fields remain.
const BOOKKEEPING_FIELDS = {
  session_meta: ["id", "cwd"],
  turn_context: ["model", "cwd", "turn_id"],
  compacted: []
};

function windowRecord(record) {
  const fields = BOOKKEEPING_FIELDS[record.type];
  if (!fields) return slimRecord(record);
  const payload = record.payload ?? {};
  return { ...record, payload: Object.fromEntries(fields.filter((field) => payload[field] != null).map((field) => [field, payload[field]])) };
}

function transcriptStem(path) {
  return path.split("/").pop().replace(/\.jsonl$/, "");
}

// rollout-<timestamp>-<thread uuid>.jsonl: the trailing uuid is the thread id.
// Used when a tail-adopted read never sees the session_meta line at offset 0.
const ROLLOUT_THREAD_ID = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/i;

function transcriptSessionId(path) {
  const stem = transcriptStem(path);
  return stem.match(ROLLOUT_THREAD_ID)?.[1] ?? stem;
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

export function isAllowedRolloutPath(root, path) {
  if (typeof path !== "string") return false;
  const name = basename(path);
  return name.startsWith("rollout-") && name.endsWith(".jsonl") && isWithin(root, path);
}

/**
 * Adds cursors for transcripts worth following. `retired` remembers files this
 * scanner gave up on, keyed by the mtime it saw, so a retired file is only
 * reconsidered once it actually changes.
 */
export async function discover({
  root,
  explicitPaths = [],
  cursors,
  retired,
  staleAfter,
  now,
  database = null,
  allowTreeFallback = false,
  conversationWindowMs,
  maxConversationRecords
}) {
  // knownModified: recency already known from the thread database, so those
  // candidates cost zero syscalls to consider — discovery runs every 2s, and
  // a stat per candidate was pure duplication of what the DB just reported.
  const consider = async (path, knownModified = null, knownId = null, exec = null) => {
    // A rollout_path comes from another program's database. Never let a
    // malformed or tampered row turn the monitor into an arbitrary file
    // reader outside the agent-owned transcript directory.
    if (!isAllowedRolloutPath(root, path)) return;
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
      // The thread id from the database (or the filename) is authoritative up
      // front: a transcript adopted from its tail never reads session_meta.
      const cursor = newCursor(knownId ?? transcriptSessionId(path), modified, database, {
        conversationWindowMs,
        maxConversationRecords
      });
      // A `codex exec` thread: its parent may come from process lineage.
      if (exec) cursor.exec = exec;
      cursors.set(path, cursor);
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
      const exec = thread.exec_created_at && typeof thread.cwd === "string" && thread.cwd
        ? { createdAt: thread.exec_created_at, cwd: thread.cwd }
        : null;
      await consider(thread.rollout_path, Number(thread.updated_at) || null, thread.id, exec);
    }
    return;
  }
  if (!allowTreeFallback) return;
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
      resetConversation(cursor);
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
      // Bounded like RecordTail: a burst past one read finishes next poll.
      const length = Math.min(metadata.size - cursor.offset, MAX_READ_BYTES);
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
        // Second consumer of the same read: timeline records feed the Codex
        // normalizer so nothing re-reads this file for events.
        if (isCodexTimelineRecord(record)) {
          const kept = windowRecord(record);
          const size = recordSize(line, record, kept);
          cursor.conversation.push(kept);
          cursor.conversationSizes.push(size);
          cursor.conversationChars += size;
        }
        const signal = signalWithApprovals(record, cursor.pendingApprovals);
        if (signal) {
          latest = stateRecord(cursor.session, signal[0], signal[1], modified, cursor.database);
          states[cursor.session] = latest;
          changed = true;
        }
      }
      pruneConversation(cursor, now * 1000);
      // A single line longer than one read would otherwise pin the cursor.
      cursor.offset += consumed === 0 && length === MAX_READ_BYTES ? bytesRead : skip + consumed;
      // Only a read that reached the end pins the rewrite-detection mtime.
      if (cursor.offset >= metadata.size) cursor.lastMtimeMs = metadata.mtimeMs;
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
