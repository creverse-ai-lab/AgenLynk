// Codex rollout transcript -> (state, event) classification.
//
// Ported from codex_app_watcher.py's signal_for/update_pending_approvals/
// signal_with_approvals. The approval tracking is the subtle part: Codex
// escalation requests and ACP permission requests both block on the human, so
// an unresolved one has to override whatever the transcript says last.

/** The plain state signal for one record, or null when it carries none. */
export function signalFor(record) {
  const payload = record?.payload ?? {};
  const kind = payload?.type;
  if (record?.type === "event_msg") {
    if (kind === "task_started" || kind === "user_message") return ["running", kind];
    if (kind === "task_complete") return ["ready", kind];
  }
  if (record?.type === "response_item" && (kind === "custom_tool_call" || kind === "function_call")) {
    const name = payload?.name;
    return [
      name === "request_user_input" ? "needs_input" : "running",
      `${kind}/${name || "unknown"}`
    ];
  }
  if (kind === "agent_message" && payload?.phase === "final_answer") return ["ready", "final_answer"];
  return null;
}

/**
 * Updates the set of unresolved approval ids and reports whether one changed.
 * `pending` is a Set of `codex:<callId>` / `acp:<requestId>` keys.
 */
export function updatePendingApprovals(record, pending) {
  const payload = record?.payload ?? {};
  const kind = payload?.type;
  let changed = false;

  if (record?.type === "response_item") {
    const callId = payload?.call_id;
    if ((kind === "custom_tool_call" || kind === "function_call") && payload?.name === "exec") {
      const toolInput = payload?.input ?? payload?.arguments ?? "";
      const text = typeof toolInput === "string" ? toolInput : JSON.stringify(toolInput);
      // Only an escalated-sandbox exec actually blocks on the human.
      if (callId && text.includes("sandbox_permissions") && text.includes("require_escalated")) {
        const before = pending.size;
        pending.add(`codex:${callId}`);
        changed = pending.size !== before;
      }
    } else if ((kind === "custom_tool_call_output" || kind === "function_call_output") && callId) {
      if (pending.delete(`codex:${callId}`)) changed = true;
    }
  }

  // ACP permission traffic can be nested anywhere inside a tool result. The
  // depth cap keeps a pathological transcript blob (a tool echoing deeply
  // nested JSON) from overflowing the stack and killing the scanner's cursor.
  const MAX_VISIT_DEPTH = 32;
  const visit = (value, depth = 0) => {
    if (depth > MAX_VISIT_DEPTH) return;
    if (Array.isArray(value)) {
      for (const child of value) visit(child, depth + 1);
      return;
    }
    if (!value || typeof value !== "object") return;
    const eventType = value.type;
    const requestId = value.requestId;
    if (requestId != null && eventType === "permission_request") {
      const key = `acp:${requestId}`;
      if (!pending.has(key)) {
        pending.add(key);
        changed = true;
      }
    } else if (requestId != null && (eventType === "permission_response" || eventType === "permission_result")) {
      if (pending.delete(`acp:${requestId}`)) changed = true;
    }
    for (const child of Object.values(value)) visit(child, depth + 1);
  };
  visit(payload?.result);

  return changed;
}

/** The state signal with unresolved approvals taken into account. */
export function signalWithApprovals(record, pending) {
  const normal = signalFor(record);
  const approvalChanged = updatePendingApprovals(record, pending);
  // A finished turn clears anything still outstanding.
  if (normal && normal[0] === "ready") pending.clear();
  if (pending.size > 0) return ["needs_input", "approval/pending"];
  if (approvalChanged) return normal ?? ["running", "approval/resolved"];
  return normal;
}
