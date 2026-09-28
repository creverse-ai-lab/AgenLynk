// ACP `session/update` traffic -> canonical monitor events.
//
// Two producers speak ACP: the Gateway (live worker events over the
// subscription) and Grok's own session log (~/.grok/sessions/<cwd>/<id>/
// updates.jsonl, one JSON-RPC notification per line). Both are mapped by the
// same `mapUpdate` so a Grok session looks identical whether AgenLynk saw it
// through the Gateway or from disk.

import {
  APPEND_BODY_LIMIT,
  EventCollector,
  contentText,
  isoTime,
  monitorEvent,
  sessionPatch,
  toolTitle,
  turnUsageList
} from "./model.js";

// Streaming messages whose chunks the Gateway normalizer keeps for ordering.
const MAX_TRACKED_MESSAGES = 64;

const TOOL_STATUS = {
  pending: "pending",
  in_progress: "running",
  inprogress: "running",
  running: "running",
  completed: "completed",
  failed: "failed",
  cancelled: "cancelled"
};

function toolStatus(value) {
  return typeof value === "string" ? TOOL_STATUS[value.toLowerCase()] ?? null : null;
}

function stopStatus(reason) {
  if (reason === "cancelled" || reason === "canceled") return "cancelled";
  if (reason === "refusal" || reason === "error") return "failed";
  return "completed";
}

function planBody(entries) {
  if (!Array.isArray(entries)) return null;
  return entries
    .map((entry) => `[${entry?.status ?? "pending"}] ${entry?.content ?? ""}`.trim())
    .join("\n");
}

/**
 * Maps one ACP update onto the collector. `context` carries the running turn
 * and the message segment counter: consecutive chunks of one kind form one
 * message, and anything else (a tool call, a thought) starts the next segment.
 */
function mapUpdate(collector, update, context) {
  const type = update?.sessionUpdate ?? update?.type;
  const { ts, source } = context;
  const turnId = context.turnId;

  if (type === "agent_message_chunk" || type === "agent_thought_chunk") {
    const kind = type === "agent_message_chunk" ? "agent_message" : "agent_thought";
    if (context.lastKind !== kind) context.segment += 1;
    context.lastKind = kind;
    const text = context.chunkText ?? contentText(update.content);
    if (!text) return;
    const key = `${kind === "agent_message" ? "msg" : "thought"}:${turnId ?? "none"}:${context.segment}`;
    if (context.chunks && Number.isFinite(context.chunkSequence)) {
      // Gateway: a gap replay re-delivers earlier chunks after later ones, so
      // the body is rebuilt in daemon order instead of arrival order.
      let parts = context.chunks.get(key);
      if (!parts) {
        parts = new Map();
        context.chunks.set(key, parts);
        if (context.chunks.size > MAX_TRACKED_MESSAGES) context.chunks.delete(context.chunks.keys().next().value);
      }
      parts.set(context.chunkSequence, text);
      const body = [...parts].sort(([left], [right]) => left - right).map(([, part]) => part).join("");
      collector.add(monitorEvent({ key, kind, ts, source, turnId, body: body.slice(0, APPEND_BODY_LIMIT) }));
      return;
    }
    collector.add(monitorEvent({ key, kind, ts, source, turnId, body: text, bodyMode: "append" }));
    return;
  }
  context.lastKind = type;

  if (type === "tool_call" || type === "tool_call_update") {
    const id = update.toolCallId;
    if (!id) return;
    const reported = toolStatus(update.status);
    if (["completed", "failed", "cancelled"].includes(reported)) context.openTools?.delete(id);
    else context.openTools?.add(id);
    const name = update._meta?.["x.ai/tool"]?.name ?? update.kind ?? null;
    const output = contentText(update.content);
    collector.add(monitorEvent({
      key: `tool:${id}`,
      kind: "tool_call",
      ts,
      source,
      turnId,
      toolCallId: id,
      title: update.title ? toolTitle(update.title, type === "tool_call" ? update.rawInput : null) : null,
      body: output || (update.rawOutput != null ? JSON.stringify(update.rawOutput) : null),
      status: toolStatus(update.status) ?? (type === "tool_call" ? "running" : null),
      endedAt: ["completed", "failed", "cancelled"].includes(toolStatus(update.status)) ? ts : null,
      detail: {
        name,
        input: update.rawInput != null ? JSON.stringify(update.rawInput) : null,
        locations: Array.isArray(update.locations)
          ? update.locations.map((location) => location?.path).filter(Boolean).slice(0, 20)
          : null
      }
    }));
    return;
  }

  if (type === "plan") {
    collector.add(monitorEvent({
      key: `plan:${turnId ?? "none"}`, kind: "plan", ts, source, turnId, title: "Plan", body: planBody(update.entries)
    }));
    return;
  }

  if (type === "subagent_spawned" || type === "subagent_finished") {
    const child = update.child_session_id ?? update.subagent_id;
    if (!child) return;
    const finished = type === "subagent_finished";
    collector.add(monitorEvent({
      key: `subagent:${child}`,
      kind: "subagent",
      ts,
      source,
      turnId,
      title: update.description ?? update.subagent_type ?? null,
      body: finished ? update.output ?? null : null,
      status: finished ? (update.status === "failed" ? "failed" : "completed") : "running",
      endedAt: finished ? ts : null,
      detail: {
        childSessionId: child,
        subagentType: update.subagent_type,
        model: update.model,
        tokensUsed: update.tokens_used,
        toolCalls: update.tool_calls
      }
    }));
  }
}

/**
 * approved / denied / cancelled for a Gateway permission response, from the
 * kind of the option chosen (ACP: allow_once/allow_always/reject_once/
 * reject_always); no option chosen is a cancellation. null when unknowable.
 */
function permissionResponseOutcome(event, options) {
  const explicit = event.outcome ?? event.data?.outcome;
  if (["approved", "denied", "cancelled"].includes(explicit)) return explicit;
  if (event.optionId == null) return "cancelled";
  const kind = (options ?? []).find((option) => option?.optionId === event.optionId)?.kind ?? String(event.optionId);
  if (/^allow/i.test(kind)) return "approved";
  if (/^reject|^deny/i.test(kind)) return "denied";
  return null;
}

/** Closes the tool calls a finished turn left open, with the turn's outcome. */
function closeOpenTools(collector, context, ts, status, turnId) {
  for (const id of context.openTools ?? []) {
    collector.add(monitorEvent({
      key: `tool:${id}`, kind: "tool_call", ts, source: context.source, turnId, toolCallId: id, status, endedAt: ts
    }));
  }
  context.openTools?.clear();
}

/**
 * Grok's updates.jsonl window -> events + session facts. Pure over the window.
 * Permission prompts are not in this file; they only arrive through hooks.
 */
export function normalizeGrokUpdates(records) {
  const collector = new EventCollector();
  const context = { turnId: null, segment: 0, lastKind: null, ts: null, source: "transcript", openTools: new Set() };
  let pendingPrompt = null;
  let model = null;
  let status = null;
  let statusAt = null;
  let turnUsage = null;
  const turns = new Map();

  for (const record of Array.isArray(records) ? records : []) {
    const params = record?.params;
    const update = params?.update;
    if (!update || typeof update !== "object") continue;
    const meta = params._meta ?? {};
    const ts = isoTime(meta.agentTimestampMs) ?? isoTime(record.timestamp);
    context.ts = ts;
    const type = update.sessionUpdate;

    if (type === "hook_execution") {
      if (update.event_name === "user_prompt_submit" && update.prompt_id) pendingPrompt = update.prompt_id;
      continue;
    }
    if (type === "user_message_chunk") {
      const text = contentText(update.content);
      if (typeof update._meta?.modelId === "string") model = update._meta.modelId;
      const promptId = meta.promptId ?? pendingPrompt ?? meta.eventId ?? ts;
      if (context.turnId !== promptId) {
        context.turnId = promptId;
        context.segment = 0;
        context.lastKind = null;
      }
      if (!turns.has(promptId)) turns.set(promptId, { turnId: promptId, startedAt: ts, running: true });
      collector.add(monitorEvent({
        key: `turn:${promptId}`, kind: "turn_start", ts, source: "transcript", turnId: promptId,
        title: text, body: text, bodyMode: "append"
      }));
      status = "running";
      statusAt = ts;
      pendingPrompt = null;
      continue;
    }
    if (meta.promptId && context.turnId !== meta.promptId) {
      // Joined mid-turn (the window starts after the prompt).
      context.turnId = meta.promptId;
      context.segment = 0;
      context.lastKind = null;
    }
    if (type === "turn_completed") {
      const ended = update.prompt_id ?? context.turnId;
      if (ended) {
        collector.add(monitorEvent({
          key: `turn:${ended}:end`, kind: "turn_end", ts, source: "transcript", turnId: ended,
          status: stopStatus(update.stop_reason),
          detail: { durationMs: update.elapsed_ms, stopReason: update.stop_reason }
        }));
      }
      closeOpenTools(collector, context, ts, stopStatus(update.stop_reason), ended);
      if (update.usage) turnUsage = update.usage;
      if (ended) {
        const turn = turns.get(ended) ?? { turnId: ended };
        turns.set(ended, {
          ...turn,
          running: false,
          endedAt: ts,
          totalTokens: Number.isFinite(Number(update.usage?.totalTokens)) ? Number(update.usage.totalTokens) : null,
          outputTokens: Number.isFinite(Number(update.usage?.outputTokens)) ? Number(update.usage.outputTokens) : null,
          contextUsed: Number.isFinite(Number(meta.totalTokens)) ? Number(meta.totalTokens) : null
        });
      }
      status = "idle";
      statusAt = ts;
      context.turnId = null;
      continue;
    }
    mapUpdate(collector, update, context);
    const running = context.turnId ? turns.get(context.turnId) : null;
    if (running?.running && Number.isFinite(Number(meta.totalTokens))) running.contextUsed = Number(meta.totalTokens);
    if (context.turnId && ["tool_call", "tool_call_update", "agent_message_chunk", "agent_thought_chunk"].includes(type)) {
      status = "running";
      statusAt = ts;
    }
  }

  return {
    events: collector.list(),
    session: sessionPatch({ model, status, statusAt, turnId: context.turnId, lastTurnUsage: turnUsage ?? null, turns: turnUsageList(turns) })
  };
}

/**
 * Grok's per-session usage.json and signals.json -> canonical usage. The
 * session totals in usage.json are authoritative; signals.json adds the live
 * context gauge.
 */
export function grokUsage(usageFile, signalsFile) {
  const session = usageFile?.session;
  const usage = {};
  if (session && typeof session === "object") {
    Object.assign(usage, {
      inputTokens: session.inputTokens,
      outputTokens: session.outputTokens,
      cacheReadTokens: session.cachedReadTokens,
      cacheWriteTokens: session.cacheCreationTokens,
      reasoningTokens: session.reasoningTokens,
      totalTokens: session.totalTokens,
      // Grok bills in 1e-10 USD "ticks".
      costUsd: Number.isFinite(Number(session.costUsdTicks)) ? Number(session.costUsdTicks) / 1e10 : null
    });
  }
  if (signalsFile && typeof signalsFile === "object") {
    usage.contextUsed = signalsFile.contextTokensUsed;
    usage.contextWindow = signalsFile.contextWindowTokens;
  }
  return {
    usage,
    model: typeof session?.primaryModelId === "string" ? session.primaryModelId : null
  };
}

/**
 * Live Gateway subscription events for one session -> canonical events.
 * Stateful (turn, segment, chunk parts) because Gateway chunks stream one at
 * a time; each chunk re-emits its message's whole body in daemon order.
 */
/**
 * A Gateway 1.6 caller as a monitor reference: the Main's local session when it
 * exported one, else its control-server instance (Codex exports no thread id).
 */
export function callerRef(caller) {
  if (!caller || typeof caller !== "object") return null;
  if (caller.provider && caller.sessionId) return `local:${caller.provider}:${caller.sessionId}`;
  return caller.instanceId ? `caller:${caller.instanceId}` : null;
}

export class GatewayEventNormalizer {
  constructor() {
    this.context = { turnId: null, segment: 0, lastKind: null, ts: null, source: "gateway", chunks: new Map(), openTools: new Set() };
    // requestId -> offered options, so a response's optionId says whether it
    // allowed or rejected (the response carries only the id).
    this.permissionOptions = new Map();
    // turnId -> the Main that started it, so the turn's end is addressed back.
    this.turnCallers = new Map();
  }

  ingest(event) {
    const collector = new EventCollector();
    if (!event || typeof event !== "object") return [];
    const ts = isoTime(event.ts) ?? new Date().toISOString();
    const context = this.context;
    context.ts = ts;
    if (event.turnId && context.turnId !== event.turnId) {
      context.turnId = event.turnId;
      context.segment = 0;
      context.lastKind = null;
    }
    const turnId = context.turnId;
    const type = event.type;

    switch (type) {
      case "turn_start": {
        const from = callerRef(event.promptedBy);
        if (from && turnId) {
          this.turnCallers.set(turnId, from);
          if (this.turnCallers.size > 200) this.turnCallers.delete(this.turnCallers.keys().next().value);
        }
        collector.add(monitorEvent({
          key: `turn:${turnId ?? ts}`, kind: "turn_start", ts, source: "gateway", turnId,
          title: event.text ?? null, body: event.text ?? null, from
        }));
        break;
      }
      case "turn_completed":
      case "turn_end":
        collector.add(monitorEvent({
          key: `turn:${turnId ?? ts}:end`, kind: "turn_end", ts, source: "gateway", turnId,
          status: stopStatus(event.stopReason), detail: { stopReason: event.stopReason },
          to: turnId ? this.turnCallers.get(turnId) ?? null : null
        }));
        closeOpenTools(collector, context, ts, stopStatus(event.stopReason), turnId);
        context.lastKind = type;
        break;
      case "agent_message_chunk":
      case "agent_thought_chunk":
        context.chunkText = typeof event.text === "string" ? event.text : null;
        context.chunkSequence = event.sequence;
        mapUpdate(collector, { sessionUpdate: type }, context);
        context.chunkText = null;
        context.chunkSequence = null;
        break;
      case "permission_request":
        if (event.requestId != null && Array.isArray(event.options)) {
          this.permissionOptions.set(String(event.requestId), event.options);
          if (this.permissionOptions.size > 200) this.permissionOptions.delete(this.permissionOptions.keys().next().value);
        }
        collector.add(monitorEvent({
          key: `perm:${event.requestId ?? ts}`, kind: "permission_request", ts, source: "gateway", turnId,
          toolCallId: event.toolCall?.toolCallId ?? null,
          title: event.toolCall?.title ?? "Permission request", status: "pending",
          detail: { requestId: event.requestId, options: Array.isArray(event.options) ? event.options.map((option) => option?.name ?? option?.kind).filter(Boolean) : null }
        }));
        context.lastKind = type;
        break;
      case "permission_response":
      case "permission_result": {
        const outcome = permissionResponseOutcome(event, this.permissionOptions.get(String(event.requestId)));
        collector.add(monitorEvent({
          key: `perm:${event.requestId ?? ts}`, kind: "permission_request", ts, source: "gateway", turnId,
          status: outcome === "approved" ? "completed" : outcome === "denied" ? "failed" : outcome === "cancelled" ? "cancelled" : "completed",
          endedAt: ts, detail: { outcome }
        }));
        break;
      }
      case "elicitation_request":
        collector.add(monitorEvent({
          key: `input:${event.requestId ?? ts}`, kind: "input_request", ts, source: "gateway", turnId,
          title: "Input requested", body: typeof event.message === "string" ? event.message : null, status: "pending"
        }));
        context.lastKind = type;
        break;
      case "session_closed":
        collector.add(monitorEvent({ key: "session:end", kind: "session_end", ts, source: "gateway", turnId, status: "completed" }));
        break;
      case "error":
        collector.add(monitorEvent({
          key: `error:${event.sequence ?? ts}`, kind: "error", ts, source: "gateway", turnId,
          title: event.message ?? event.text ?? "Error", status: "failed"
        }));
        break;
      default:
        if (event.data && typeof event.data === "object") mapUpdate(collector, event.data, context);
    }
    return collector.list({ keepAppend: true });
  }
}
