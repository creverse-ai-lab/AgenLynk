// Pure projection of Codex conversation records into monitor events. The
// records themselves come from the local-agents codex tailer, which retains a
// conversation window from the same single read that produces session state —
// there is deliberately no file reader here anymore.
const DEFAULT_HISTORY_MS = 65 * 60 * 1000;

export function projectCodexTranscript(records, {
  sessionId,
  rawSessionId,
  now = Date.now(),
  historyMs = DEFAULT_HISTORY_MS
}) {
  const cutoff = now - historyMs;
  const events = [];
  const timestampCounts = new Map();
  const callNames = new Map();
  let currentTurnId = null;

  const push = (record, type, values = {}) => {
    const milliseconds = Date.parse(record.timestamp ?? "");
    if (!Number.isFinite(milliseconds) || milliseconds < cutoff) return;
    const count = timestampCounts.get(milliseconds) ?? 0;
    timestampCounts.set(milliseconds, count + 1);
    events.push({
      sessionId,
      sequence: milliseconds * 100 + count,
      type,
      ts: new Date(milliseconds).toISOString(),
      turnId: currentTurnId,
      source: "local-transcript",
      ...values
    });
  };

  for (const record of records) {
    const payload = record?.payload ?? {};
    if (record.type === "response_item" && payload.type === "message" && payload.role === "user") {
      const text = messageText(payload.content);
      if (!text) continue;
      currentTurnId = `local-turn:${rawSessionId}:${Date.parse(record.timestamp ?? "")}`;
      push(record, "turn_start", { text });
      continue;
    }
    if (!currentTurnId) continue;
    if (record.type === "response_item" && payload.type === "message" && payload.role === "assistant") {
      const text = messageText(payload.content);
      if (text) push(record, "agent_message_chunk", { text });
      continue;
    }
    if (record.type === "response_item" && ["custom_tool_call", "function_call"].includes(payload.type)) {
      const name = payload.name ?? payload.type;
      if (payload.call_id) callNames.set(payload.call_id, name);
      push(record, "tool_call", {
        text: summarizeToolCall(name, payload.input ?? payload.arguments),
        toolCallId: payload.call_id ?? payload.id ?? null
      });
      continue;
    }
    if (record.type === "response_item" && ["custom_tool_call_output", "function_call_output"].includes(payload.type)) {
      push(record, "tool_call_update", {
        text: `${callNames.get(payload.call_id) ?? "tool"} 완료`,
        toolCallId: payload.call_id ?? payload.id ?? null
      });
      continue;
    }
    if (record.type === "event_msg" && payload.type === "task_complete") {
      push(record, "turn_end", { stopReason: "completed" });
      currentTurnId = null;
      continue;
    }
    if (record.type === "event_msg" && ["turn_aborted", "stream_error"].includes(payload.type)) {
      push(record, "error", { text: payload.message ?? payload.type });
      currentTurnId = null;
    }
  }
  return events;
}

export function isConversationRecord(record) {
  const type = record?.payload?.type;
  return (record?.type === "response_item" && [
    "message", "custom_tool_call", "function_call", "custom_tool_call_output", "function_call_output"
  ].includes(type)) || (record?.type === "event_msg" && ["task_complete", "turn_aborted", "stream_error"].includes(type));
}

function messageText(content) {
  return (Array.isArray(content) ? content : [])
    .map((item) => item?.text)
    .filter((value) => typeof value === "string" && value.length)
    .join("\n");
}

function summarizeToolCall(name, input) {
  const raw = typeof input === "string" ? input : JSON.stringify(input ?? "");
  const compact = raw.replace(/\s+/g, " ").trim();
  return compact ? `${name}: ${compact.slice(0, 240)}` : name;
}
