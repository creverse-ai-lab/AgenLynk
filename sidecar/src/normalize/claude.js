// Claude Code transcript (~/.claude/projects/<project>/<session>.jsonl and
// <session>/subagents/agent-<id>.jsonl) -> canonical monitor events.
//
// Pure over a window of records: the same window always yields the same keys,
// so re-normalizing on every read is safe and the store dedupes. Token usage is
// the one cumulative fact a window cannot answer; ClaudeUsageAccumulator is fed
// each record exactly once by the tailer instead.

import {
  EventCollector,
  contentText,
  isoTime,
  monitorEvent,
  preview,
  sessionPatch,
  toolTitle,
  turnUsageList
} from "./model.js";

const SOURCE = "transcript";
const INTERRUPT_PREFIX = "[Request interrupted by user";
// Slash-command bookkeeping Claude writes as user records; not a prompt.
const COMMAND_RECORD = /^\s*<(command-name|command-message|local-command-stdout|local-command-stderr|local-command-caveat)>/;

function blocks(record) {
  const content = record?.message?.content;
  return Array.isArray(content) ? content : [];
}

function isToolResultRecord(record) {
  return blocks(record).some((block) => block?.type === "tool_result");
}

/** A record belongs to the session line being normalized. */
export function inScope(record, agentId) {
  if (agentId) return record?.agentId === agentId;
  return record?.isSidechain !== true;
}

function toolOutput(block, record) {
  const text = contentText(block?.content);
  if (text) return text;
  const result = record?.toolUseResult;
  if (typeof result === "string") return result;
  if (result && typeof result === "object") {
    return [result.stdout, result.stderr].filter((part) => typeof part === "string" && part).join("\n") || null;
  }
  return null;
}

/**
 * @param {object[]} records transcript records, oldest first
 * @param {{ agentId?: string|null }} options restrict to one Task subagent line
 * @returns {{ events: object[], session: object }}
 */
export function normalizeClaudeRecords(records, { agentId = null } = {}) {
  const events = new EventCollector();
  let turnId = null;
  let model = null;
  let cwd = null;
  let title = null;
  let status = null;
  let statusAt = null;
  let contextUsed = null;
  const openTools = new Set();
  // turnId -> {turnId, startedAt, endedAt, running, messages: Map<id, usage>}
  const turns = new Map();
  const turnEntry = (id) => {
    if (!turns.has(id)) turns.set(id, { turnId: id, running: true, messages: new Map() });
    return turns.get(id);
  };

  const setStatus = (value, at) => {
    status = value;
    statusAt = at ?? statusAt;
  };
  const endTurn = (ts, outcome, detail = null) => {
    if (!turnId) return;
    // A tool still open when its turn ends never reports back: it went with
    // the turn (an interrupt kills it), so it must not spin forever.
    for (const id of openTools) {
      events.add(monitorEvent({
        key: `tool:${id}`, kind: "tool_call", ts, source: SOURCE, turnId, toolCallId: id, status: outcome, endedAt: ts
      }));
    }
    events.add(monitorEvent({
      key: `turn:${turnId}:end`, kind: "turn_end", ts, source: SOURCE, turnId, status: outcome, detail
    }));
    const entry = turnEntry(turnId);
    entry.running = false;
    entry.endedAt = ts;
    setStatus("idle", ts);
    turnId = null;
    openTools.clear();
  };

  for (const record of Array.isArray(records) ? records : []) {
    if (!record || typeof record !== "object") continue;
    if (record.type === "ai-title" && typeof record.aiTitle === "string") {
      title = record.aiTitle;
      continue;
    }
    if (!inScope(record, agentId)) continue;
    const ts = isoTime(record.timestamp);
    if (typeof record.cwd === "string" && record.cwd) cwd = record.cwd;

    if (record.type === "user" && !record.isMeta) {
      if (isToolResultRecord(record)) {
        for (const block of blocks(record)) {
          if (block?.type !== "tool_result" || !block.tool_use_id) continue;
          openTools.delete(block.tool_use_id);
          events.add(monitorEvent({
            key: `tool:${block.tool_use_id}`,
            kind: "tool_call",
            ts,
            source: SOURCE,
            turnId,
            toolCallId: block.tool_use_id,
            body: toolOutput(block, record),
            status: block.is_error ? "failed" : "completed",
            endedAt: ts
          }));
        }
        continue;
      }
      const text = contentText(record.message?.content);
      if (!text || COMMAND_RECORD.test(text)) continue;
      if (text.startsWith(INTERRUPT_PREFIX)) {
        endTurn(ts, "cancelled");
        continue;
      }
      // A new prompt while a turn is open (queued input) stays in that turn.
      if (turnId) {
        events.add(monitorEvent({
          key: `user:${record.uuid ?? ts}`, kind: "user_message", ts, source: SOURCE, turnId, body: text
        }));
        continue;
      }
      turnId = record.promptId ?? record.uuid ?? `turn-${ts}`;
      turnEntry(turnId).startedAt = ts;
      events.add(monitorEvent({
        key: `turn:${turnId}`, kind: "turn_start", ts, source: SOURCE, turnId, title: text, body: text
      }));
      setStatus("running", ts);
      continue;
    }

    if (record.type === "assistant") {
      const message = record.message ?? {};
      if (typeof message.model === "string" && message.model && message.model !== "<synthetic>") model = message.model;
      const usage = message.usage;
      if (usage && typeof usage === "object") {
        contextUsed = [usage.input_tokens, usage.cache_read_input_tokens, usage.cache_creation_input_tokens]
          .map(Number).filter(Number.isFinite).reduce((sum, value) => sum + value, 0) || contextUsed;
        // One record per content block repeats the message's usage: keyed by
        // message id so a turn counts each model call once.
        if (turnId && (message.id ?? record.uuid)) {
          const output = Number(usage.output_tokens) || 0;
          turnEntry(turnId).messages.set(message.id ?? record.uuid, { input: contextUsed ?? 0, output });
        }
      }
      if (record.isApiErrorMessage === true) {
        events.add(monitorEvent({
          key: `error:${record.uuid ?? ts}`, kind: "error", ts, source: SOURCE, turnId,
          title: contentText(message.content) || "API error", status: "failed"
        }));
        setStatus("error", ts);
        continue;
      }
      blocks(record).forEach((block, index) => {
        const id = `${record.uuid ?? message.id ?? ts}:${index}`;
        if (block?.type === "text" && block.text) {
          events.add(monitorEvent({ key: `msg:${id}`, kind: "agent_message", ts, source: SOURCE, turnId, body: block.text }));
        } else if (block?.type === "thinking" && block.thinking) {
          events.add(monitorEvent({ key: `thought:${id}`, kind: "agent_thought", ts, source: SOURCE, turnId, body: block.thinking }));
        } else if (block?.type === "tool_use" && block.id) {
          openTools.add(block.id);
          events.add(monitorEvent({
            key: `tool:${block.id}`,
            kind: "tool_call",
            ts,
            source: SOURCE,
            turnId,
            toolCallId: block.id,
            title: toolTitle(block.name, block.input),
            status: "running",
            detail: { name: block.name, input: JSON.stringify(block.input ?? null) }
          }));
        }
      });
      if (turnId) setStatus("running", ts);
      continue;
    }

    if (record.type === "system") {
      if (record.subtype === "turn_duration") {
        endTurn(ts, "completed", { durationMs: record.durationMs });
      } else if (record.subtype === "compact_boundary") {
        events.add(monitorEvent({
          key: `compact:${record.uuid ?? ts}`, kind: "compaction", ts, source: SOURCE, turnId, title: "Context compacted"
        }));
      } else if (record.subtype === "api_error") {
        events.add(monitorEvent({
          key: `error:${record.uuid ?? ts}`, kind: "error", ts, source: SOURCE, turnId,
          title: preview(record.content ?? record.error?.message ?? "API error"), status: "failed"
        }));
      }
    }
  }

  return {
    events: events.list(),
    session: sessionPatch({
      model,
      cwd,
      title,
      status,
      statusAt,
      turnId,
      openToolCount: openTools.size,
      turns: turnUsageList(new Map([...turns].map(([id, turn]) => {
        const calls = [...turn.messages.values()];
        return [id, {
          ...turn,
          totalTokens: calls.length ? calls.reduce((sum, call) => sum + call.input + call.output, 0) : null,
          outputTokens: calls.length ? calls.reduce((sum, call) => sum + call.output, 0) : null,
          contextUsed: calls.at(-1)?.input ?? null
        }];
      }))),
      usage: contextUsed != null ? { contextUsed } : null
    })
  };
}

/**
 * Session token totals from assistant records, fed each record once. Claude
 * writes one record per content block and repeats the same message usage on
 * each, so totals are kept per message id (last wins) and summed.
 */
const USAGE_PARTS = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens", "reasoningTokens"];
// Message ids whose usage may still be repeated. Claude repeats a message's
// usage only on that message's own (adjacent) records, so older ids are
// folded into a running sum instead of being remembered forever.
const OPEN_MESSAGE_LIMIT = 256;

export class ClaudeUsageAccumulator {
  constructor({ openMessageLimit = OPEN_MESSAGE_LIMIT } = {}) {
    this.byMessage = new Map();
    this.openMessageLimit = openMessageLimit;
    this.folded = null;
  }

  add(record) {
    if (record?.type !== "assistant") return false;
    const message = record.message ?? {};
    const usage = message.usage;
    const id = message.id ?? record.uuid;
    if (!id || !usage || typeof usage !== "object") return false;
    // Re-set moves the id to the newest end, so folding takes the oldest.
    this.byMessage.delete(id);
    this.byMessage.set(id, {
      inputTokens: finite(usage.input_tokens),
      outputTokens: finite(usage.output_tokens),
      cacheReadTokens: finite(usage.cache_read_input_tokens),
      cacheWriteTokens: finite(usage.cache_creation_input_tokens),
      reasoningTokens: finite(usage.output_tokens_details?.thinking_tokens)
    });
    while (this.byMessage.size > this.openMessageLimit) {
      const [oldest, parts] = this.byMessage.entries().next().value;
      this.byMessage.delete(oldest);
      this.folded ??= Object.fromEntries(USAGE_PARTS.map((field) => [field, 0]));
      for (const field of USAGE_PARTS) this.folded[field] += parts[field] ?? 0;
    }
    return true;
  }

  totals() {
    if (!this.byMessage.size && !this.folded) return null;
    const total = Object.fromEntries(USAGE_PARTS.map((field) => [field, this.folded?.[field] ?? 0]));
    for (const usage of this.byMessage.values()) {
      for (const field of USAGE_PARTS) total[field] += usage[field] ?? 0;
    }
    // Canonical inputTokens include cached input (as Codex and Grok report
    // it); Claude reports the three parts separately.
    total.inputTokens += total.cacheReadTokens + total.cacheWriteTokens;
    total.totalTokens = total.inputTokens + total.outputTokens;
    return total;
  }
}

function finite(value) {
  const number = Number(value);
  return value != null && Number.isFinite(number) ? number : null;
}
