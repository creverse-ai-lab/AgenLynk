// Canonical monitor model shared by every source (Claude, Codex, Grok, the
// Gateway, and agent hooks). Each normalizer turns its provider's records into
// these shapes so the store and the app never branch on where an event came
// from. The JSON Schema in contracts/monitor/v2/ mirrors this file.

export const EVENT_KINDS = Object.freeze([
  "session_start",
  "session_end",
  "turn_start",
  "turn_end",
  "user_message",
  "agent_message",
  "agent_thought",
  "tool_call",
  "permission_request",
  "input_request",
  "subagent",
  "plan",
  "compaction",
  "error"
]);

export const EVENT_STATUSES = Object.freeze(["pending", "running", "completed", "failed", "cancelled"]);

// The Gateway's own vocabulary; local sources map onto the same words.
export const SESSION_STATUSES = Object.freeze([
  "running",
  "waiting_permission",
  "waiting_input",
  "idle",
  "cancelling",
  "restoring",
  "closed",
  "unavailable",
  "error",
  "disconnected"
]);

export const EVENT_SOURCES = Object.freeze(["transcript", "hook", "gateway", "process"]);

// Token semantics are the same for every provider: inputTokens include cached
// input, totalTokens = inputTokens + outputTokens, reasoningTokens are part of
// outputTokens, contextUsed is the prompt size of the latest model call.
export const USAGE_FIELDS = Object.freeze([
  "inputTokens",
  "outputTokens",
  "cacheReadTokens",
  "cacheWriteTokens",
  "reasoningTokens",
  "totalTokens",
  "contextUsed",
  "contextWindow",
  "costUsd"
]);

export const TITLE_LIMIT = 240;
export const BODY_LIMIT = 8_000;
export const DETAIL_LIMIT = 2_000;

const KIND_SET = new Set(EVENT_KINDS);
const STATUS_SET = new Set(EVENT_STATUSES);
const SOURCE_SET = new Set(EVENT_SOURCES);

/** Cuts text to `limit` UTF-16 units on a whitespace-normalized preview. */
export function clip(value, limit) {
  if (value == null) return null;
  const text = typeof value === "string" ? value : JSON.stringify(value);
  if (typeof text !== "string" || !text.length) return null;
  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
}

/** One-line preview: whitespace collapsed, then clipped. */
export function preview(value, limit = TITLE_LIMIT) {
  const text = clip(value, limit * 4);
  if (!text) return null;
  return clip(text.replace(/\s+/g, " ").trim(), limit);
}

/**
 * ISO timestamp from whatever a provider writes: an ISO string, epoch
 * milliseconds, or epoch seconds. Returns null when nothing usable is given.
 */
export function isoTime(value) {
  const ms = epochMs(value);
  return ms == null ? null : new Date(ms).toISOString();
}

/** Epoch milliseconds from the same inputs as isoTime, or null. */
export function epochMs(value) {
  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }
  if (typeof value === "number" && Number.isFinite(value) && value > 0) {
    // Anything below 10^11 cannot be milliseconds after 1973.
    return value < 1e11 ? value * 1_000 : value;
  }
  return null;
}

/**
 * A canonical timeline event. `key` must be stable for the same fact across
 * re-reads and across sources (hook vs transcript), because the store upserts
 * on it; everything else may be refined by a later observation of that key.
 *
 * `bodyMode: "append"` marks a streamed chunk the store concatenates onto the
 * existing body instead of replacing it (Gateway message chunks).
 *
 * `from` / `to` name the other end of a message when a source proves it: a
 * turn a Main started through the Gateway comes from that Main, and its end
 * goes back to it (Gateway 1.6 `promptedBy`). Absent, not guessed, otherwise.
 */
export function monitorEvent({
  key,
  kind,
  ts,
  source,
  turnId = null,
  toolCallId = null,
  title = null,
  body = null,
  status = null,
  endedAt = null,
  detail = null,
  bodyMode = "replace",
  from = null,
  to = null
}) {
  if (typeof key !== "string" || !key) throw new TypeError("monitor event key is required");
  if (!KIND_SET.has(kind)) throw new TypeError(`unknown monitor event kind: ${kind}`);
  if (!SOURCE_SET.has(source)) throw new TypeError(`unknown monitor event source: ${source}`);
  const event = {
    key,
    kind,
    ts: isoTime(ts) ?? new Date().toISOString(),
    turnId: turnId ?? null,
    toolCallId: toolCallId ?? null,
    title: preview(title),
    body: bodyMode === "append" ? (typeof body === "string" ? body : null) : clip(body, BODY_LIMIT),
    status: STATUS_SET.has(status) ? status : null,
    endedAt: isoTime(endedAt),
    sources: [source]
  };
  const compactDetail = compactObject(detail);
  if (compactDetail) event.detail = compactDetail;
  if (bodyMode === "append") event.bodyMode = "append";
  if (typeof from === "string" && from) event.from = from;
  if (typeof to === "string" && to) event.to = to;
  return event;
}

function compactObject(value) {
  if (!value || typeof value !== "object") return null;
  const entries = Object.entries(value)
    .filter(([, item]) => item != null && item !== "")
    .map(([name, item]) => [name, typeof item === "string" ? clip(item, DETAIL_LIMIT) : item]);
  return entries.length ? Object.fromEntries(entries) : null;
}

/** Usage with every field null: "the provider said nothing", never zero. */
export function emptyUsage() {
  return Object.fromEntries(USAGE_FIELDS.map((field) => [field, null]));
}

/** Keeps only finite numbers for known usage fields; null when nothing is known. */
export function normalizeUsage(value) {
  if (!value || typeof value !== "object") return null;
  const usage = emptyUsage();
  let known = false;
  for (const field of USAGE_FIELDS) {
    const number = Number(value[field]);
    if (value[field] != null && Number.isFinite(number)) {
      usage[field] = number;
      known = true;
    }
  }
  if (!known) return null;
  if (usage.totalTokens == null && usage.inputTokens != null && usage.outputTokens != null) {
    usage.totalTokens = usage.inputTokens + usage.outputTokens;
  }
  return usage;
}

/** Field-wise overlay: a later known value replaces an earlier one. */
export function overlayUsage(base, patch) {
  const next = normalizeUsage(patch);
  if (!next) return base ?? null;
  if (!base) return next;
  const merged = { ...base };
  for (const field of USAGE_FIELDS) if (next[field] != null) merged[field] = next[field];
  return merged;
}

/**
 * Session facts a normalizer learned. Every field is optional; a consumer
 * overlays non-null fields onto what it already knows. `status` comes with the
 * `statusAt` it was observed at so the newest source wins.
 */
export function sessionPatch(values = {}) {
  const patch = {};
  for (const [name, value] of Object.entries(values)) {
    if (value == null) continue;
    if (name === "usage") {
      const usage = normalizeUsage(value);
      if (usage) patch.usage = usage;
      continue;
    }
    patch[name] = value;
  }
  return patch;
}

/** Tool name + argument preview, e.g. "Bash: ls -la". */
export function toolTitle(name, input) {
  const label = typeof name === "string" && name ? name : "tool";
  const argument = summarizeInput(input);
  return argument ? `${label}: ${argument}` : label;
}

function summarizeInput(input) {
  if (input == null) return null;
  if (typeof input === "string") return preview(input, 200);
  if (typeof input !== "object") return preview(String(input), 200);
  // The fields agents actually put the interesting part in, in priority order.
  for (const field of ["command", "cmd", "file_path", "path", "target_directory", "pattern", "query", "url", "description", "prompt"]) {
    const value = input[field];
    if (typeof value === "string" && value) return preview(value, 200);
    if (Array.isArray(value) && value.length) return preview(value.join(" "), 200);
  }
  return preview(JSON.stringify(input), 200);
}

/** Plain text out of the content shapes the providers use. */
export function contentText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) {
    if (content && typeof content === "object") {
      if (typeof content.text === "string") return content.text;
      if (content.content != null) return contentText(content.content);
    }
    return "";
  }
  return content
    .map((item) => {
      if (typeof item === "string") return item;
      if (typeof item?.text === "string") return item.text;
      if (item?.content != null) return contentText(item.content);
      return "";
    })
    .filter(Boolean)
    .join("\n");
}

const TERMINAL_STATUSES = new Set(["completed", "failed", "cancelled"]);
export const APPEND_BODY_LIMIT = BODY_LIMIT * 4;

/**
 * Folds a later observation of the same key into an earlier one. Shared by
 * every normalizer (a tool_use and its tool_result in one window) and by the
 * store (a hook and a transcript describing the same call):
 * - non-null fields refine, the first `ts` stays;
 * - a terminal status never regresses to pending/running;
 * - `append` bodies concatenate (bounded);
 * - `sources` accumulate.
 */
export function mergeEvent(existing, incoming) {
  if (!existing) return { ...incoming };
  const merged = { ...existing };
  for (const field of ["title", "turnId", "toolCallId", "endedAt", "from", "to"]) {
    if (incoming[field] != null) merged[field] = incoming[field];
  }
  if (incoming.body != null) {
    if (incoming.bodyMode === "append") {
      const combined = `${existing.body ?? ""}${incoming.body}`;
      merged.body = combined.length > APPEND_BODY_LIMIT ? `${combined.slice(0, APPEND_BODY_LIMIT - 1)}…` : combined;
      merged.bodyMode = "append";
    } else {
      merged.body = incoming.body;
    }
  }
  if (incoming.status != null && !(TERMINAL_STATUSES.has(existing.status) && !TERMINAL_STATUSES.has(incoming.status))) {
    merged.status = incoming.status;
  }
  if (Date.parse(incoming.ts) < Date.parse(existing.ts)) merged.ts = incoming.ts;
  if (incoming.detail) merged.detail = { ...(existing.detail ?? {}), ...incoming.detail };
  merged.sources = [...new Set([...(existing.sources ?? []), ...(incoming.sources ?? [])])];
  return merged;
}

/** Ordered, key-deduplicated event list built with mergeEvent. */
export class EventCollector {
  constructor() {
    this.byKey = new Map();
  }

  add(event) {
    if (!event) return;
    this.byKey.set(event.key, mergeEvent(this.byKey.get(event.key), event));
  }

  /**
   * Events oldest first. Chunks appended inside one window are already whole
   * here, so by default they leave as plain replacements: re-normalizing the
   * same window must never make the store append the text a second time.
   */
  list({ keepAppend = false } = {}) {
    // Each timestamp parsed once, not once per comparison (a 2,000-event
    // window took ~32,000 parses). Array.prototype.sort is stable, as before.
    return [...this.byKey.values()]
      .map((event) => {
        const kept = keepAppend || event.bodyMode !== "append" ? event : (({ bodyMode, ...rest }) => rest)(event);
        return { event: kept, at: Date.parse(kept.ts) };
      })
      .sort((left, right) => left.at - right.at)
      .map((entry) => entry.event);
  }
}

export const TURN_USAGE_LIMIT = 20;

/**
 * Per-turn token use, newest last, for the usage forecast. Same meaning as
 * session usage: totalTokens = input (incl. cache) + output across the turn's
 * model calls; contextUsed is the prompt size of the turn's last call.
 * A running turn reports what it has used so far.
 */
export function turnUsageList(turns) {
  return [...turns.values()]
    .filter((turn) => turn.totalTokens != null || turn.running)
    .slice(-TURN_USAGE_LIMIT)
    .map((turn) => ({
      turnId: turn.turnId,
      startedAt: turn.startedAt ?? null,
      endedAt: turn.endedAt ?? null,
      running: turn.running === true,
      totalTokens: turn.totalTokens ?? null,
      outputTokens: turn.outputTokens ?? null,
      contextUsed: turn.contextUsed ?? null
    }));
}
