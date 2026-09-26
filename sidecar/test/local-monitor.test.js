import assert from "node:assert/strict";
import test from "node:test";
import { mergeMonitorSessions, projectLocalSnapshot } from "../src/local-monitor.js";
import { currentProjectedTurnId, projectCodexTranscript } from "../src/local-transcript.js";

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

// Regression: the state scan invents `local-turn:<session>` for a running
// session because it cannot see turn boundaries, while the transcript
// projection numbers each turn `local-turn:<session>:<startedAt>`. When the
// projection supplies a session's events, the session record has to adopt
// their turn id — the menu-bar live graph scopes events to the session's
// current turn, so a record pointing at a turn none of its events belongs to
// draws a running session with nothing in it.
test("a running local session adopts the turn id its projected events carry", () => {
  const records = [
    { timestamp: "2026-08-07T00:00:00.000Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "first" }] } },
    { timestamp: "2026-08-07T00:00:01.000Z", type: "event_msg", payload: { type: "task_complete" } },
    { timestamp: "2026-08-07T00:00:02.000Z", type: "response_item", payload: { type: "message", role: "user", content: [{ type: "input_text", text: "second" }] } },
    { timestamp: "2026-08-07T00:00:03.000Z", type: "response_item", payload: { type: "message", role: "assistant", content: [{ type: "output_text", text: "working" }] } }
  ];
  const [session] = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", time: 100, cwd: "/work" }
  ] }).sessions;
  const events = projectCodexTranscript(records, {
    sessionId: session.sessionId,
    rawSessionId: session.localSessionId,
    now: Date.parse("2026-08-07T00:01:00.000Z")
  });

  const adopted = currentProjectedTurnId(events);
  assert.notEqual(adopted, session.turnId, "the scan's synthetic id is not a real turn id");
  assert.equal(adopted, events.at(-1).turnId);
  assert.ok(events.some((event) => event.turnId === adopted && event.type === "turn_start"),
    "the adopted turn must be one the events actually opened");
  assert.equal(currentProjectedTurnId([]), null);
});

test("local snapshot projects a real frontdoor and nested local workers", () => {
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", event: "task_started", time: 100, engine: "gpt", cwd: "/work" },
    { provider: "codex", session: "child", parent: "main", state: "running", event: "agent", time: 101, engine: "gpt", cwd: "/work" },
    { provider: "claude", session: "grandchild", parent: "gateway-owned", state: "needs_input", event: "approval", time: 102, engine: "sonnet", cwd: "/work" },
    { provider: "grok", session: "gateway-owned", parent: "child", state: "running", time: 103 }
  ] });

  assert.equal(projected.sessions.length, 4);
  const root = projected.sessions.find((session) => session.localSessionId === "main");
  const grandchild = projected.sessions.find((session) => session.localSessionId === "grandchild");
  assert.equal(root.sessionId, "local:codex:main");
  assert.equal(root.role, "frontdoor");
  assert.equal(root.openerInstanceId, "main");
  assert.equal(grandchild.role, "worker");
  assert.equal(grandchild.openerInstanceId, "main", "an intermediate parent must not create a false Frontdoor");
  assert.equal(grandchild.status, "waiting_input");
  assert.equal(projected.events[root.sessionId][0].type, "turn_start");
});

test("a local parent id uses the parent's provider and is never minted for an unseen parent", () => {
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "claude-main", state: "running", time: 100 },
    { provider: "codex", session: "codex-child", parent: "claude-main", state: "running", time: 101 },
    { provider: "grok", session: "orphan", parent: "not-in-snapshot", state: "running", time: 102 }
  ] });
  const byId = new Map(projected.sessions.map((session) => [session.localSessionId, session]));
  assert.equal(byId.get("codex-child").parentSessionId, "local:claude:claude-main");
  assert.equal(byId.get("orphan").parentSessionId, null, "no local:grok:<unseen> id may be invented");
  assert.equal(byId.get("orphan").parentLocalSessionId, "not-in-snapshot", "the raw link stays for Gateway resolution");
});

test("gateway-owned provider sessions are deduplicated by ACP or Gateway id", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", time: 100 },
    // No marker flag: a Gateway-owned claude worker writes an ordinary
    // transcript, so the scanner reports it like any other local session.
    // ownedWorkerIds in mergeMonitorSessions is what must dedupe it.
    { provider: "claude", session: "provider-worker", parent: "main", state: "running", time: 101 },
    { provider: "grok", session: "nested-worker", parent: "provider-worker", state: "running", time: 102 }
  ] });
  const merged = mergeMonitorSessions([
    // Gateway 1.4 omits topology; the duplicate provider transcript supplies
    // it before that local record is removed.
    { sessionId: "gateway-worker", acpSessionId: "provider-worker", provider: "claude", status: "running" }
  ], local.sessions);

  assert.deepEqual(merged.map((session) => session.sessionId), [
    "gateway-worker", "local:codex:main", "local:grok:nested-worker"
  ]);
  assert.equal(merged[0].opener, "codex");
  assert.equal(merged[0].openerInstanceId, "main");
  assert.equal(merged[0].role, "worker");
  assert.equal(merged[0].parentSessionId, "local:codex:main");
  assert.equal(merged[1].openerInstanceId, merged[0].openerInstanceId);
  assert.equal(merged[2].parentSessionId, "gateway-worker", "a local subagent must connect to its Gateway parent");
});

// Regression: before the frontdoor's gateway tool response is scanned, the
// worker's transcript roots to itself. Copying that self-rooted identity onto
// the Gateway record promoted every not-yet-linked running worker to a false
// Frontdoor row of its own.
test("an unlinked gateway worker is never promoted to a Frontdoor", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "frontdoor-uuid", state: "running", time: 100, cwd: "/repo" },
    { provider: "claude", session: "worker-uuid", state: "running", time: 101, cwd: "/repo" }
  ] });
  const merged = mergeMonitorSessions([
    { sessionId: "acp-1", acpSessionId: "worker-uuid", provider: "claude", status: "running" }
  ], local.sessions);

  const gatewayRecord = merged.find((session) => session.sessionId === "acp-1");
  assert.equal(gatewayRecord.role, "worker", "a Gateway session is opened by a Main, never a Frontdoor");
  assert.equal(gatewayRecord.openerInstanceId, undefined, "a self-rooted identity must not be copied");
  const frontdoors = merged.filter((session) => session.role === "frontdoor");
  assert.deepEqual(frontdoors.map((session) => session.openerInstanceId), ["frontdoor-uuid"],
    "only the real Frontdoor keeps a root identity");
});

// Regression: the transcript that proves a worker's parent leaves the scan
// seconds after its turn ends, which stripped the Gateway record's topology
// again — workers detached from their Frontdoor between turns and their
// events vanished from the Frontdoor's sequence view.
test("worker attribution is remembered after its transcript goes stale", () => {
  const workerTopology = new Map();
  const linked = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "frontdoor-uuid", state: "running", time: 100, cwd: "/repo" },
    { provider: "claude", session: "worker-uuid", parent: "frontdoor-uuid", state: "running", time: 101, cwd: "/repo" }
  ] });
  const gateway = [{ sessionId: "acp-1", acpSessionId: "worker-uuid", provider: "claude", status: "running" }];

  const first = mergeMonitorSessions(gateway, linked.sessions, workerTopology);
  assert.equal(first[0].openerInstanceId, "frontdoor-uuid");

  // The worker went idle; readyAfter expired and its transcript left the scan.
  const second = mergeMonitorSessions([{ ...gateway[0], status: "idle" }], [], workerTopology);
  assert.equal(second[0].role, "worker");
  assert.equal(second[0].openerInstanceId, "frontdoor-uuid", "attribution survives the transcript going stale");
  assert.equal(second[0].parentSessionId, "local:claude:frontdoor-uuid");
});
