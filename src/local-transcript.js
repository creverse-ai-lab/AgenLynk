import { execFile } from "node:child_process";
import { open, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const SESSION_ID = /^[A-Za-z0-9_-]{1,160}$/;
const DEFAULT_HISTORY_MS = 65 * 60 * 1000;

export class LocalTranscriptReader {
  constructor({
    databasePath = join(homedir(), ".codex", "state_5.sqlite"),
    historyMs = DEFAULT_HISTORY_MS,
    initialTailBytes = 12 * 1024 * 1024
  } = {}) {
    this.databasePath = databasePath;
    this.historyMs = historyMs;
    this.initialTailBytes = initialTailBytes;
    this.paths = new Map();
    this.files = new Map();
  }

  async enrich(projection) {
    const codexSessions = projection.sessions.filter((session) =>
      session.source === "local" && session.provider === "codex" && SESSION_ID.test(session.localSessionId ?? "")
    );
    await this.resolvePaths(codexSessions.map((session) => session.localSessionId));
    for (const session of codexSessions) {
      const path = this.paths.get(session.localSessionId);
      if (!path) continue;
      const records = await this.readRecords(path);
      const events = projectCodexTranscript(records, {
        sessionId: session.sessionId,
        rawSessionId: session.localSessionId,
        now: Date.now(),
        historyMs: this.historyMs
      });
      if (events.length) projection.events[session.sessionId] = events;
    }
    return projection;
  }

  async resolvePaths(sessionIds) {
    const unknown = [...new Set(sessionIds)].filter((id) => !this.paths.has(id));
    if (!unknown.length) return;
    const quoted = unknown.map((id) => `'${id}'`).join(",");
    try {
      const { stdout } = await execFileAsync("sqlite3", [
        "-json",
        this.databasePath,
        `select id, rollout_path from threads where id in (${quoted})`
      ], { maxBuffer: 1024 * 1024 });
      for (const row of JSON.parse(stdout || "[]")) {
        if (SESSION_ID.test(row.id ?? "") && typeof row.rollout_path === "string") {
          this.paths.set(row.id, row.rollout_path);
        }
      }
    } catch {
      // Local monitoring continues with status-only events when sqlite3 or the
      // Codex database is unavailable.
    }
  }

  async readRecords(path) {
    let metadata;
    try {
      metadata = await stat(path);
    } catch {
      return [];
    }
    let cached = this.files.get(path);
    if (cached && cached.size === metadata.size) return cached.records;
    if (!cached || metadata.size < cached.size) {
      cached = { size: Math.max(0, metadata.size - this.initialTailBytes), remainder: "", records: [] };
    }
    const start = cached.size;
    const length = Math.max(0, metadata.size - start);
    if (!length) return cached.records;
    const handle = await open(path, "r");
    try {
      const buffer = Buffer.alloc(length);
      await handle.read(buffer, 0, length, start);
      let text = cached.remainder + buffer.toString("utf8");
      if (!cached.records.length && start > 0) {
        const firstNewline = text.indexOf("\n");
        text = firstNewline >= 0 ? text.slice(firstNewline + 1) : "";
      }
      const lines = text.split("\n");
      cached.remainder = lines.pop() ?? "";
      for (const line of lines) {
        try {
          const record = JSON.parse(line);
          if (isConversationRecord(record)) cached.records.push(record);
        } catch {
          // Ignore a racing or malformed transcript line.
        }
      }
      const cutoff = Date.now() - this.historyMs;
      cached.records = cached.records.filter((record) => Date.parse(record.timestamp ?? "") >= cutoff);
      cached.size = metadata.size;
      this.files.set(path, cached);
      return cached.records;
    } finally {
      await handle.close();
    }
  }
}

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

function isConversationRecord(record) {
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
