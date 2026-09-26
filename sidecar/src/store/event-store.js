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
      // `floorMs`: timestamp of the newest event the cap evicted. A source
      // re-reads its whole window every pass; without the floor, every event
      // older than the cap would be re-inserted (new sequence, a database
      // write, an SSE frame) and evicted again on every tick.
      bucket = { byKey: new Map(), nextSequence: 1, sorted: null, floorMs: -Infinity, touchedAt: Date.now() };
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
    bucket.touchedAt = Date.now();
    const changed = [];
    // The sorted view survives a pass that only appends in order (the common
    // live case); anything else re-sorts on the next read.
    // Callers may hold the previous array (a snapshot being serialized), so
    // it is copied, never mutated.
    let sorted = bucket.sorted;
    let copied = false;
    let lastMs = sorted?.length ? timeOf(sorted.at(-1)) : -Infinity;
    let lastSequence = sorted?.at(-1)?.sequence ?? 0;
    for (const incoming of events) {
      if (!incoming?.key) continue;
      const existing = bucket.byKey.get(incoming.key);
      // Already capped away: older than everything memory still holds.
      if (!existing && timeOf(incoming) <= bucket.floorMs) continue;
      const merged = mergeEvent(existing, incoming);
      if (existing && sameEvent(existing, merged)) continue;
      merged.sessionId = sessionId;
      merged.sequence = existing?.sequence ?? bucket.nextSequence++;
      merged.id = `${sessionId}#${merged.key}`;
      delete merged.bodyMode;
      bucket.byKey.set(merged.key, merged);
      changed.push(merged);
      if (sorted) {
        const ms = timeOf(merged);
        if (!existing && (ms > lastMs || (ms === lastMs && merged.sequence > lastSequence))) {
          if (!copied) {
            sorted = sorted.slice();
            copied = true;
          }
          sorted.push(merged);
          lastMs = ms;
          lastSequence = merged.sequence;
        } else {
          sorted = null;
        }
      }
    }
    if (!changed.length) return changed;
    bucket.sorted = sorted;
    this.#cap(bucket);
    this.persistence?.writeEvents(sessionId, changed);
    // What the cap evicted in this same pass is persisted history, but not
    // news for a live view that would drop it again.
    return changed.length && bucket.byKey.size >= this.maxEventsPerSession
      ? changed.filter((event) => bucket.byKey.get(event.key) === event)
      : changed;
  }

  /** ms since the last upsert into `sessionId`, or null without a bucket. */
  idleMs(sessionId, now = Date.now()) {
    const bucket = this.sessions.get(sessionId);
    return bucket ? now - bucket.touchedAt : null;
  }

  /** Events oldest first (by timestamp, then store sequence). */
  list(sessionId, { limit = null } = {}) {
    const bucket = this.sessions.get(sessionId);
    if (!bucket) return [];
    if (!bucket.sorted) bucket.sorted = sortEvents(bucket.byKey.values());
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
    return sortEvents(byKey.values()).slice(-limit);
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
    const ordered = bucket.sorted ?? sortEvents(bucket.byKey.values());
    for (let index = 0; index < overflow; index += 1) {
      const event = ordered[index];
      bucket.byKey.delete(event.key);
      bucket.floorMs = Math.max(bucket.floorMs, timeOf(event));
    }
    bucket.sorted = ordered.slice(overflow);
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

function timeOf(event) {
  const ms = Date.parse(event?.ts ?? "");
  return Number.isFinite(ms) ? ms : 0;
}

/** Oldest first (timestamp, then store sequence), parsing each ts once. */
function sortEvents(values) {
  return [...values]
    .map((event) => [timeOf(event), event])
    .sort((left, right) => (left[0] - right[0]) || ((left[1].sequence ?? 0) - (right[1].sequence ?? 0)))
    .map(([, event]) => event);
}
