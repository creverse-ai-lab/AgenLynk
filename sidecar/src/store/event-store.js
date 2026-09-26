// Canonical event store: one keyed, merged timeline per session.
//
// Every source writes here through `upsert`, keyed by the normalizer's stable
// event key, so a tool call seen by a hook and again in the transcript is one
// event with two sources, and a transcript re-read never duplicates anything.
// The store — not any source — assigns `sequence`, so ordering and the app's
// event ids never depend on a Gateway daemon's counter or a file's mtime.

import { mergeEvent } from "../normalize/model.js";

const DEFAULT_MAX_EVENTS_PER_SESSION = 2_000;

export class EventStore {
  /**
   * @param {{ maxEventsPerSession?: number, persistence?: object|null }} options
   * `persistence` (see sqlite-store.js) receives every changed event and may
   * hold more history than memory does.
   */
  constructor({ maxEventsPerSession = DEFAULT_MAX_EVENTS_PER_SESSION, persistence = null } = {}) {
    this.maxEventsPerSession = maxEventsPerSession;
    this.persistence = persistence;
    this.sessions = new Map();
    this.overflowDropped = 0;
  }

  #bucket(sessionId) {
    let bucket = this.sessions.get(sessionId);
    if (!bucket) {
      bucket = { byKey: new Map(), nextSequence: 1, sorted: null };
      this.sessions.set(sessionId, bucket);
    }
    return bucket;
  }

  has(sessionId) {
    return (this.sessions.get(sessionId)?.byKey.size ?? 0) > 0;
  }

  sessionIds() {
    return [...this.sessions.keys()];
  }

  /**
   * Merges `events` (canonical, from ../normalize) into the session. Returns
   * the events that actually changed, in their merged form.
   */
  upsert(sessionId, events) {
    if (!sessionId || !Array.isArray(events) || !events.length) return [];
    const bucket = this.#bucket(sessionId);
    const changed = [];
    for (const incoming of events) {
      if (!incoming?.key) continue;
      const existing = bucket.byKey.get(incoming.key);
      const merged = mergeEvent(existing, incoming);
      if (existing && sameEvent(existing, merged)) continue;
      merged.sessionId = sessionId;
      merged.sequence = existing?.sequence ?? bucket.nextSequence++;
      merged.id = `${sessionId}#${merged.key}`;
      delete merged.bodyMode;
      bucket.byKey.set(merged.key, merged);
      changed.push(merged);
    }
    if (!changed.length) return changed;
    bucket.sorted = null;
    this.#cap(bucket);
    this.persistence?.writeEvents(sessionId, changed);
    return changed;
  }

  /** Events oldest first (by timestamp, then store sequence). */
  list(sessionId, { limit = null } = {}) {
    const bucket = this.sessions.get(sessionId);
    if (!bucket) return [];
    if (!bucket.sorted) bucket.sorted = [...bucket.byKey.values()].sort(eventOrder);
    return limit != null && bucket.sorted.length > limit ? bucket.sorted.slice(-limit) : bucket.sorted;
  }

  /** Older events for paging: those with sequence < `before`, newest `limit`. */
  page(sessionId, { before = Infinity, limit = 200 } = {}) {
    const inMemory = this.list(sessionId).filter((event) => event.sequence < before);
    if (inMemory.length >= limit || !this.persistence) return inMemory.slice(-limit);
    // Memory is newer than the last flush; the database holds what memory
    // capped away. Both, deduplicated by key, newest `limit`.
    this.persistence.flush?.();
    const byKey = new Map(this.persistence.readEvents(sessionId, { before, limit }).map((event) => [event.key, event]));
    for (const event of inMemory) byKey.set(event.key, event);
    return [...byKey.values()].sort(eventOrder).slice(-limit);
  }

  /** Restores persisted events without re-persisting them. */
  load(sessionId, events) {
    const bucket = this.#bucket(sessionId);
    for (const event of events) {
      if (!event?.key) continue;
      bucket.byKey.set(event.key, event);
      if (event.sequence >= bucket.nextSequence) bucket.nextSequence = event.sequence + 1;
    }
    bucket.sorted = null;
    this.#cap(bucket);
  }

  /** Drops a session from memory; persisted history stays. */
  evict(sessionId) {
    this.sessions.delete(sessionId);
  }

  #cap(bucket) {
    const overflow = bucket.byKey.size - this.maxEventsPerSession;
    if (overflow <= 0) return;
    const oldest = [...bucket.byKey.values()].sort(eventOrder).slice(0, overflow);
    for (const event of oldest) bucket.byKey.delete(event.key);
    bucket.sorted = null;
    this.overflowDropped += overflow;
  }
}

function sameEvent(left, right) {
  for (const field of ["title", "body", "status", "endedAt", "turnId", "toolCallId", "ts"]) {
    if ((left[field] ?? null) !== (right[field] ?? null)) return false;
  }
  if ((left.sources ?? []).length !== (right.sources ?? []).length) return false;
  return JSON.stringify(left.detail ?? null) === JSON.stringify(right.detail ?? null);
}

export function eventOrder(left, right) {
  const byTime = Date.parse(left.ts) - Date.parse(right.ts);
  if (byTime) return byTime;
  return (left.sequence ?? 0) - (right.sequence ?? 0);
}
