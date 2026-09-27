// Codex rollout transcript (~/.codex/sessions/**/rollout-*.jsonl) -> canonical
// monitor events.
//
// Messages, reasoning and compaction come from `event_msg/item_completed`,
// which carries only what the user and the agent actually said. The raw
// `response_item/message` records also hold injected developer/context text
// and are deliberately not used. Tool calls come from `response_item`
// function/custom calls (start) and their outputs (end), joined by `call_id`.
// Usage is cumulative in `token_count`, so a window is enough.

import {
  EventCollector,
  contentText,
  isoTime,
  monitorEvent,
  sessionPatch,
  toolTitle,
  turnUsageList
} from "./model.js";

const SOURCE = "transcript";
const TOOL_CALL_TYPES = new Set(["custom_tool_call", "function_call", "local_shell_call"]);
const TOOL_OUTPUT_TYPES = new Set(["custom_tool_call_output", "function_call_output", "local_shell_call_output"]);

/** Records the Codex tailer must retain in its window for this normalizer. */
export function isCodexTimelineRecord(record) {
  const type = record?.type;
  const kind = record?.payload?.type;
  if (type === "turn_context" || type === "session_meta" || type === "compacted") return true;
  if (type === "response_item") return TOOL_CALL_TYPES.has(kind) || TOOL_OUTPUT_TYPES.has(kind);
  if (type === "event_msg") {
    return ["task_started", "task_complete", "turn_aborted", "stream_error", "error", "item_completed", "token_count"]
      .includes(kind);
  }
  return false;
}

function parseInput(value) {
  if (typeof value !== "string") return value ?? null;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

// Codex's code-mode `exec` tool takes a JavaScript snippet that calls
// tools.exec_command({cmd: ...}) and friends. The snippet is noise in a
// timeline; the commands it runs are what a person wants to read.
const CODE_MODE_CALL = /tools\.([A-Za-z_]+)\(\s*(\{[\s\S]*?\})\s*\)/g;

function codeModeSummary(code) {
  if (typeof code !== "string" || !code.includes("tools.")) return null;
  const calls = [];
  for (const match of code.matchAll(CODE_MODE_CALL)) {
    let args = null;
    try {
      args = JSON.parse(match[2]);
    } catch {
      // Not literal JSON (built at runtime): name the tool alone.
    }
    calls.push({ name: match[1], args });
  }
  if (!calls.length) return null;
  const [first] = calls;
  const extra = calls.length > 1 ? ` (+${calls.length - 1})` : "";
  return { name: first.name, input: first.args, extra };
}

/** A tool output that reports a non-zero exit or an error, e.g. a sandbox denial. */
function outputFailed(payload) {
  const parsed = parseInput(payload?.output);
  const exit = parsed?.metadata?.exit_code ?? parsed?.exit_code;
  if (Number.isFinite(Number(exit)) && Number(exit) !== 0) return true;
  if (payload?.success === false || parsed?.success === false) return true;
  const text = typeof payload?.output === "string" ? payload.output : "";
  return /^(Script failed|Error:|error:)/.test(text.trim());
}

function outputText(payload) {
  const output = payload?.output;
  if (typeof output === "string") {
    // function_call_output often wraps {"output": "...", "metadata": {...}}.
    const parsed = parseInput(output);
    if (parsed && typeof parsed === "object" && typeof parsed.output === "string") return parsed.output;
    return output;
  }
  return contentText(output);
}

function usageFrom(info) {
  const total = info?.total_token_usage;
  if (!total || typeof total !== "object") return null;
  const last = info?.last_token_usage;
  return {
    inputTokens: total.input_tokens,
    outputTokens: total.output_tokens,
    cacheReadTokens: total.cached_input_tokens,
    cacheWriteTokens: total.cache_write_input_tokens,
    reasoningTokens: total.reasoning_output_tokens,
    totalTokens: total.total_tokens,
    contextUsed: last?.input_tokens ?? null,
    contextWindow: info.model_context_window ?? null
  };
}

/**
 * @param {object[]} records rollout records, oldest first
 * @returns {{ events: object[], session: object }}
 */
export function normalizeCodexRecords(records) {
  const events = new EventCollector();
  let turnId = null;
  let model = null;
  let cwd = null;
  let status = null;
  let statusAt = null;
  let usage = null;
  let contextWindow = null;
  const toolNames = new Map();
  const openTools = new Set();
  const closeOpenTools = (ts, status, ended) => {
    for (const id of openTools) {
      events.add(monitorEvent({
        key: `tool:${id}`, kind: "tool_call", ts, source: SOURCE, turnId: ended, toolCallId: id, status, endedAt: ts
      }));
    }
    openTools.clear();
  };
  // Turns whose opening prompt already landed on turn_start.
  const promptedTurns = new Set();
  // Codex reports cumulative totals; a turn's use is the difference between
  // the totals at its end and at its start.
  const turns = new Map();
  let lastTotal = null;
  let lastOutput = null;

  const setStatus = (value, at) => {
    status = value;
    statusAt = at ?? statusAt;
  };

  for (const record of Array.isArray(records) ? records : []) {
    if (!record || typeof record !== "object") continue;
    const payload = record.payload ?? {};
    const ts = isoTime(record.timestamp);
    const recordTurn = payload.turn_id ?? payload.internal_chat_message_metadata_passthrough?.turn_id ?? null;

    if (record.type === "session_meta") {
      if (typeof payload.cwd === "string") cwd = payload.cwd;
      // The window starts at the session's beginning: nothing was used yet.
      if (lastTotal == null) {
        lastTotal = 0;
        lastOutput = 0;
      }
      continue;
    }
    if (record.type === "turn_context") {
      if (typeof payload.model === "string" && payload.model) model = payload.model;
      if (typeof payload.cwd === "string" && payload.cwd) cwd = payload.cwd;
      continue;
    }
    if (record.type === "compacted") {
      events.add(monitorEvent({ key: `compact:${ts}`, kind: "compaction", ts, source: SOURCE, turnId, title: "Context compacted" }));
      continue;
    }

    if (record.type === "event_msg") {
      if (payload.type === "task_started") {
        turnId = recordTurn ?? `turn-${ts}`;
        if (payload.model_context_window != null) contextWindow = payload.model_context_window;
        turns.set(turnId, { turnId, startedAt: ts, running: true, baseTotal: lastTotal, baseOutput: lastOutput });
        events.add(monitorEvent({ key: `turn:${turnId}`, kind: "turn_start", ts, source: SOURCE, turnId }));
        setStatus("running", ts);
      } else if (payload.type === "task_complete") {
        const ended = recordTurn ?? turnId;
        if (ended) {
          events.add(monitorEvent({
            key: `turn:${ended}:end`, kind: "turn_end", ts, source: SOURCE, turnId: ended, status: "completed",
            detail: { durationMs: payload.duration_ms }
          }));
        }
        closeOpenTools(ts, "completed", ended);
        if (turns.has(ended)) Object.assign(turns.get(ended), { running: false, endedAt: ts });
        setStatus("idle", ts);
        turnId = null;
      } else if (payload.type === "turn_aborted") {
        const ended = recordTurn ?? turnId;
        if (ended) {
          events.add(monitorEvent({
            key: `turn:${ended}:end`, kind: "turn_end", ts, source: SOURCE, turnId: ended, status: "cancelled",
            title: payload.reason ?? null
          }));
        }
        closeOpenTools(ts, "cancelled", ended);
        if (turns.has(ended)) Object.assign(turns.get(ended), { running: false, endedAt: ts });
        setStatus("idle", ts);
        turnId = null;
      } else if (payload.type === "stream_error" || payload.type === "error") {
        events.add(monitorEvent({
          key: `error:${ts}:${payload.type}`, kind: "error", ts, source: SOURCE, turnId,
          title: payload.message ?? payload.type, status: "failed"
        }));
      } else if (payload.type === "token_count") {
        usage = usageFrom(payload.info) ?? usage;
        const total = Number(payload.info?.total_token_usage?.total_tokens);
        const output = Number(payload.info?.total_token_usage?.output_tokens);
        const turn = turnId ? turns.get(turnId) : null;
        if (turn && Number.isFinite(total)) {
          // Adopted mid-turn: the first report's own call is the known floor.
          if (turn.baseTotal == null) {
            turn.baseTotal = total - (Number(payload.info?.last_token_usage?.total_tokens) || 0);
            turn.baseOutput = output - (Number(payload.info?.last_token_usage?.output_tokens) || 0);
          }
          turn.totalTokens = total - turn.baseTotal;
          turn.outputTokens = Number.isFinite(output) ? output - (turn.baseOutput ?? 0) : null;
          turn.contextUsed = Number(payload.info?.last_token_usage?.input_tokens) || null;
        }
        if (Number.isFinite(total)) lastTotal = total;
        if (Number.isFinite(output)) lastOutput = output;
      } else if (payload.type === "item_completed") {
        addItem(events, payload.item, ts, recordTurn ?? turnId, payload, promptedTurns);
      }
      continue;
    }

    if (record.type === "response_item") {
      const callId = payload.call_id ?? payload.id ?? null;
      if (!callId) continue;
      if (TOOL_CALL_TYPES.has(payload.type)) {
        const name = payload.name ?? payload.type;
        const input = parseInput(payload.input ?? payload.arguments ?? payload.action);
        const code = codeModeSummary(input);
        toolNames.set(callId, name);
        openTools.add(callId);
        events.add(monitorEvent({
          key: `tool:${callId}`, kind: "tool_call", ts, source: SOURCE, turnId: recordTurn ?? turnId, toolCallId: callId,
          title: code ? `${toolTitle(code.name, code.input)}${code.extra}` : toolTitle(name, input), status: "running",
          detail: { name, input: typeof input === "string" ? input : JSON.stringify(input) }
        }));
        if (turnId) setStatus("running", ts);
      } else if (TOOL_OUTPUT_TYPES.has(payload.type)) {
        openTools.delete(callId);
        events.add(monitorEvent({
          key: `tool:${callId}`, kind: "tool_call", ts, source: SOURCE, turnId: recordTurn ?? turnId, toolCallId: callId,
          body: outputText(payload), status: outputFailed(payload) ? "failed" : "completed", endedAt: ts
        }));
      }
    }
  }

  if (usage && usage.contextWindow == null && contextWindow != null) usage.contextWindow = contextWindow;
  return {
    events: events.list(),
    session: sessionPatch({ model, cwd, status, statusAt, turnId, usage, turns: turnUsageList(turns) })
  };
}

function addItem(events, item, ts, turnId, payload, promptedTurns) {
  if (!item || typeof item !== "object" || !item.id) return;
  const at = isoTime(payload.started_at_ms) ?? ts;
  if (item.type === "UserMessage") {
    const text = contentText(item.content);
    if (!text) return;
    // The turn's opening prompt is the turn_start itself (as for Claude and
    // Grok); only later input inside the same turn is a separate user_message.
    if (turnId && !promptedTurns.has(turnId)) {
      promptedTurns.add(turnId);
      events.add(monitorEvent({ key: `turn:${turnId}`, kind: "turn_start", ts: at, source: SOURCE, turnId, title: text, body: text }));
      return;
    }
    events.add(monitorEvent({ key: `user:${item.id}`, kind: "user_message", ts: at, source: SOURCE, turnId, body: text }));
  } else if (item.type === "AgentMessage") {
    const text = contentText(item.content);
    if (text) events.add(monitorEvent({ key: `msg:${item.id}`, kind: "agent_message", ts: at, source: SOURCE, turnId, body: text }));
  } else if (item.type === "Reasoning") {
    const text = [...(item.summary_text ?? []), ...(item.raw_content ?? [])]
      .map((part) => (typeof part === "string" ? part : part?.text))
      .filter(Boolean)
      .join("\n");
    if (text) events.add(monitorEvent({ key: `thought:${item.id}`, kind: "agent_thought", ts: at, source: SOURCE, turnId, body: text }));
  } else if (item.type === "ContextCompaction") {
    events.add(monitorEvent({ key: `compact:${item.id}`, kind: "compaction", ts: at, source: SOURCE, turnId, title: "Context compacted" }));
  }
}
