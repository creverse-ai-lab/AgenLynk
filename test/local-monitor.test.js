import assert from "node:assert/strict";
import test from "node:test";
import { mergeMonitorSessions, projectLocalSnapshot } from "../src/local-monitor.js";
import { projectCodexTranscript } from "../src/local-transcript.js";

test("Codex transcript projection preserves prompt, assistant messages, tools, and completion", () => {
  const records = [
    { timestamp: "2026-08-07T00:00:00.000Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "inspect sessions" }] } },
    { timestamp: "2026-08-07T00:00:01.000Z", type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "checking now" }] } },
    { timestamp: "2026-08-07T00:00:02.000Z", type: "response_item", payload: { type: "custom_tool_call", name: "exec", call_id: "call-1", input: "sqlite3 state.db" } },
    { timestamp: "2026-08-07T00:00:03.000Z", type: "response_item", payload: { type: "custom_tool_call_output", call_id: "call-1", output: "ignored large output" } },
    { timestamp: "2026-08-07T00:00:04.000Z", type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "mapping is correct" }] } },
    { timestamp: "2026-08-07T00:00:05.000Z", type: "event_msg", payload: { type: "task_complete" } }
  ];
  const events = projectCodexTranscript(records, {
    sessionId: "local:codex:main",
    rawSessionId: "main",
    now: Date.parse("2026-08-07T00:01:00.000Z")
  });

  assert.deepEqual(events.map((event) => event.type), [
    "turn_start", "agent_message_chunk", "tool_call", "tool_call_update", "agent_message_chunk", "turn_end"
  ]);
  assert.equal(events[0].text, "inspect sessions");
  assert.equal(events[1].text, "checking now");
  assert.match(events[2].text, /exec: sqlite3 state\.db/);
  assert.equal(events[4].text, "mapping is correct");
  assert.ok(events.every((event) => event.turnId === events[0].turnId));
});

test("local snapshot projects a real frontdoor and nested local workers", () => {
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", event: "task_started", time: 100, engine: "gpt", cwd: "/work" },
    { provider: "codex", session: "child", parent: "main", state: "running", event: "agent", time: 101, engine: "gpt", cwd: "/work" },
    { provider: "claude", session: "grandchild", parent: "gateway-owned", state: "needs_input", event: "approval", time: 102, engine: "sonnet", cwd: "/work" },
    { provider: "grok", session: "gateway-owned", parent: "child", state: "running", time: 103, delegated: true }
  ] });

  assert.equal(projected.sessions.length, 3);
  const root = projected.sessions.find((session) => session.localSessionId === "main");
  const grandchild = projected.sessions.find((session) => session.localSessionId === "grandchild");
  assert.equal(root.sessionId, "local:codex:main");
  assert.equal(root.role, "frontdoor");
  assert.equal(root.openerInstanceId, "main");
  assert.equal(grandchild.role, "worker");
  assert.equal(grandchild.openerInstanceId, "main", "a delegated intermediate parent must not create a false Frontdoor");
  assert.equal(grandchild.status, "waiting_input");
  assert.equal(projected.events[root.sessionId][0].type, "turn_start");
});

test("gateway-owned provider sessions are deduplicated by ACP or Gateway id", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", time: 100 },
    { provider: "claude", session: "provider-worker", parent: "main", state: "running", time: 101, delegated: true },
    { provider: "grok", session: "nested-worker", parent: "provider-worker", state: "running", time: 102 }
  ] });
  const merged = mergeMonitorSessions([
    { sessionId: "gateway-worker", acpSessionId: "provider-worker", openerInstanceId: "main" }
  ], local.sessions);

  assert.deepEqual(merged.map((session) => session.sessionId), [
    "gateway-worker", "local:codex:main", "local:grok:nested-worker"
  ]);
  assert.equal(merged[1].openerInstanceId, merged[0].openerInstanceId);
  assert.equal(merged[2].parentSessionId, "gateway-worker", "a local subagent must connect to its Gateway parent");
});
