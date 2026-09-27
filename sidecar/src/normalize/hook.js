// Agent hook payloads (Claude Code, Codex, Grok) -> session status + the few
// events only a hook can see.
//
// Hooks are the live channel: they say "a tool is running", "a permission
// prompt is waiting", "the turn ended" the moment it happens, where the
// transcript only shows it once something is written. The timeline itself
// still comes from the transcript. A hook adds an event only where its key is
// known to equal the transcript's (Claude's tool_use_id) or where no
// transcript records the fact at all (permission prompts).
//
// Payload shapes: Claude and Codex use snake_case keys; Grok uses camelCase
// and carries Claude's PascalCase event name in `hook_event_name`.

import { isoTime, monitorEvent, preview, toolTitle } from "./model.js";

const SOURCE = "hook";

function pascal(value) {
  if (typeof value !== "string" || !value) return null;
  if (!value.includes("_")) return value[0].toUpperCase() + value.slice(1);
  return value.split("_").map((part) => (part ? part[0].toUpperCase() + part.slice(1) : "")).join("");
}

/** Provider-neutral view of one hook payload. */
export function readHookPayload(provider, payload) {
  const value = payload && typeof payload === "object" ? payload : {};
  const pick = (...names) => {
    for (const name of names) if (value[name] != null && value[name] !== "") return value[name];
    return null;
  };
  return {
    provider,
    event: pick("hook_event_name") ?? pascal(pick("hookEventName")),
    sessionId: pick("session_id", "sessionId"),
    cwd: pick("cwd", "workspaceRoot"),
    transcriptPath: pick("transcript_path", "transcriptPath"),
    agentId: pick("agent_id", "agentId"),
    model: pick("model"),
    turnId: pick("turn_id", "promptId", "prompt_id"),
    toolName: pick("tool_name", "toolName"),
    toolInput: pick("tool_input", "toolInput"),
    toolUseId: pick("tool_use_id", "toolUseId"),
    toolResponse: pick("tool_response", "toolResult", "tool_result"),
    notificationType: pick("notification_type", "notificationType"),
    message: pick("message"),
    timestamp: pick("timestamp")
  };
}

// Hook event -> the session status it proves.
const STATUS_BY_EVENT = {
  SessionStart: "idle",
  UserPromptSubmit: "running",
  PreToolUse: "running",
  PostToolUse: "running",
  PostToolUseFailure: "running",
  PermissionDenied: "running",
  PermissionRequest: "waiting_permission",
  SubagentStart: "running",
  SubagentStop: "running",
  PreCompact: "running",
  PostCompact: "running",
  Stop: "idle",
  StopFailure: "idle",
  StopCancelled: "idle",
  Interrupt: "idle",
  SessionEnd: "closed"
};

/**
 * How an open permission prompt ended, judged by what came next: the tool
 * running means it was allowed, PermissionDenied that it was refused, and a
 * turn that ended without either that it was abandoned. Anything else (a
 * notification, a subagent) says nothing yet.
 */
function permissionOutcome(event) {
  if (event === "PreToolUse" || event === "PostToolUse" || event === "PostToolUseFailure") {
    return { status: "completed", label: "approved" };
  }
  if (event === "PermissionDenied") return { status: "failed", label: "denied" };
  if (["Stop", "StopFailure", "StopCancelled", "Interrupt", "UserPromptSubmit", "SessionEnd"].includes(event)) {
    return { status: "cancelled", label: "cancelled" };
  }
  return null;
}

function notificationStatus(type) {
  if (type === "permission_prompt") return "waiting_permission";
  if (type === "idle_prompt") return "idle";
  return null;
}

/**
 * Stateful per session: remembers the open permission prompt so the next
 * sign of progress can mark it answered.
 */
export class HookNormalizer {
  constructor() {
    this.openPermission = null;
  }

  /**
   * @returns {{ hook: object, status: string|null, statusAt: string, events: object[] }}
   */
  ingest(provider, payload, receivedAt = Date.now()) {
    const hook = readHookPayload(provider, payload);
    const ts = isoTime(hook.timestamp) ?? new Date(receivedAt).toISOString();
    const events = [];
    let status = hook.event === "Notification"
      ? notificationStatus(hook.notificationType)
      : STATUS_BY_EVENT[hook.event] ?? null;
    // Grok runs a sub-agent in a session of its own, and SubagentStop fires
    // in that session at the sub-agent's own turn end: it is that session's
    // Stop. (Claude and Codex fire it in the parent, which keeps working.)
    if (provider === "grok" && hook.event === "SubagentStop") status = "idle";
    // Inside a Task subagent the parent session is still working; the
    // subagent's own line is the transcript's business. Grok's payload is
    // always about its own session.
    if (provider !== "grok" && hook.agentId && status === "idle") status = "running";

    const waitsForPermission = status === "waiting_permission";
    const outcome = this.openPermission && !waitsForPermission ? permissionOutcome(hook.event) : null;
    if (outcome) {
      events.push(monitorEvent({
        key: this.openPermission, kind: "permission_request", ts, source: SOURCE, turnId: hook.turnId,
        status: outcome.status, endedAt: ts, detail: { outcome: outcome.label }
      }));
      this.openPermission = null;
    }
    if (waitsForPermission && !this.openPermission) {
      this.openPermission = `perm:hook:${hook.toolUseId ?? ts}`;
      events.push(monitorEvent({
        key: this.openPermission,
        kind: "permission_request",
        ts,
        source: SOURCE,
        turnId: hook.turnId,
        toolCallId: hook.toolUseId,
        title: hook.toolName ? toolTitle(hook.toolName, hook.toolInput) : preview(hook.message) ?? "Permission request",
        status: "pending",
        detail: { name: hook.toolName, notificationType: hook.notificationType }
      }));
    }

    // Claude's tool_use_id is the transcript's tool_use block id, so these
    // merge into the transcript's event; for Codex and Grok the ids are not
    // known to match, and the transcript alone carries their tool calls.
    if (provider === "claude" && !hook.agentId && hook.toolUseId) {
      if (hook.event === "PreToolUse") {
        events.push(monitorEvent({
          key: `tool:${hook.toolUseId}`, kind: "tool_call", ts, source: SOURCE, turnId: hook.turnId,
          toolCallId: hook.toolUseId, title: toolTitle(hook.toolName, hook.toolInput), status: "running"
        }));
      } else if (hook.event === "PostToolUse" || hook.event === "PostToolUseFailure") {
        events.push(monitorEvent({
          key: `tool:${hook.toolUseId}`, kind: "tool_call", ts, source: SOURCE, turnId: hook.turnId,
          toolCallId: hook.toolUseId, status: hook.event === "PostToolUse" ? "completed" : "failed", endedAt: ts
        }));
      }
    }
    if (hook.event === "SessionEnd") {
      events.push(monitorEvent({ key: "session:end", kind: "session_end", ts, source: SOURCE, status: "completed" }));
    }
    return { hook, status, statusAt: ts, events };
  }
}
