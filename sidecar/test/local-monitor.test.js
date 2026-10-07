import assert from "node:assert/strict";
import test from "node:test";
import { isMisrecordedWorker, mergeMonitorSessions, projectLocalSnapshot } from "../src/local-monitor.js";
import { normalizeCodexRecords } from "../src/normalize/codex.js";

// Regression: the state scan invents `local-turn:<session>` for a running
// session because it cannot see turn boundaries. The timeline can; the
// session record has to carry the turn its own events belong to, because the
// menu-bar live graph scopes events to the session's current turn.
test("a running local session carries the turn id and facts of its timeline", () => {
  const records = [
    { timestamp: "2026-08-07T00:00:00.000Z", type: "turn_context", payload: { turn_id: "t1", model: "gpt-5.6", cwd: "/work" } },
    { timestamp: "2026-08-07T00:00:00.000Z", type: "event_msg", payload: { type: "task_started", turn_id: "t1" } },
    { timestamp: "2026-08-07T00:00:01.000Z", type: "event_msg", payload: { type: "task_complete", turn_id: "t1" } },
    { timestamp: "2026-08-07T00:00:02.000Z", type: "event_msg", payload: { type: "task_started", turn_id: "t2" } },
    {
      timestamp: "2026-08-07T00:00:03.000Z", type: "event_msg",
      payload: { type: "token_count", info: { total_token_usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12 }, model_context_window: 1000 } }
    }
  ];
  const timeline = normalizeCodexRecords(records);
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "running", time: Date.parse("2026-08-07T00:00:02.500Z") / 1000, cwd: "/work" }
  ] }, new Map([["codex:main", timeline]]));
  const [session] = projected.sessions;

  assert.equal(session.turnId, "t2", "the session adopts the timeline's open turn, not a synthetic id");
  assert.equal(session.model, "gpt-5.6");
  assert.equal(session.usage.totalTokens, 12);
  assert.equal(session.usage.contextWindow, 1000);
  assert.equal(session.createdAt, "2026-08-07T00:00:00.000Z", "a session starts at its first event");
  assert.deepEqual(projected.events[session.sessionId].map((event) => event.kind), ["turn_start", "turn_end", "turn_start"]);
});

test("a local session without a timeline gets no invented events and no placeholder model", () => {
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "quiet", state: "ready", time: 100, engine: "claude-cli", event: "end_turn" }
  ] });
  const [session] = projected.sessions;
  assert.equal(session.status, "idle", "the scanner's ready maps onto the canonical idle");
  assert.equal(session.model, null, "claude-cli is a placeholder, not a model");
  assert.equal(session.title, null, "a scanner event name is not a title");
  assert.deepEqual(projected.events, {});
  assert.deepEqual(session.capabilities, ["status"]);
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

test("Gateway 1.6 openedBy attributes a worker without any transcript link", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "frontdoor-uuid", state: "running", time: 100, cwd: "/repo" },
    { provider: "claude", session: "worker-uuid", state: "running", time: 101, cwd: "/repo" }
  ] });
  const openedBy = { provider: "claude", sessionId: "frontdoor-uuid", pid: 4242, instanceId: "mcp-a" };
  const merged = mergeMonitorSessions([
    { sessionId: "acp-1", acpSessionId: "worker-uuid", provider: "claude", status: "running", openedBy }
  ], local.sessions, new Map());
  const worker = merged.find((session) => session.sessionId === "acp-1");
  assert.equal(worker.role, "worker");
  assert.equal(worker.parentSessionId, "local:claude:frontdoor-uuid");
  assert.equal(worker.openerInstanceId, "frontdoor-uuid", "the Main's own group, straight from the protocol");

  // The Main's session is not in the scan (yet): the caller still names it.
  const unseen = mergeMonitorSessions([
    { sessionId: "acp-2", acpSessionId: "w2", provider: "grok", status: "running",
      openedBy: { provider: "grok", sessionId: "g-main", pid: 7, instanceId: "mcp-g" } }
  ], [], new Map());
  assert.equal(unseen[0].parentSessionId, "local:grok:g-main");
  assert.equal(unseen[0].openerInstanceId, "g-main");
});

// Regression: a Grok worker the Gateway spawned in the same folder as a
// running Codex was adopted by the same-cwd fallback, and that guess was then
// taken as proof, so the worker showed up as the Codex Main's.
test("a same-cwd guess never attributes a Gateway worker", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "codex-thread", state: "running", time: 100, cwd: "/repo" },
    { provider: "grok", session: "grok-worker", parent: "codex-thread", parent_source: "cwd", state: "running", time: 101, cwd: "/repo" }
  ] });
  assert.equal(local.sessions.find((session) => session.localSessionId === "grok-worker").parentProof, "cwd");
  const merged = mergeMonitorSessions([
    { sessionId: "acp-g", acpSessionId: "grok-worker", provider: "grok", status: "running" }
  ], local.sessions, new Map());
  const worker = merged.find((session) => session.sessionId === "acp-g");
  assert.equal(worker.role, "worker");
  assert.equal(worker.openerInstanceId, undefined, "a guess is not an opener");
  assert.equal(worker.parentSessionId ?? null, null);
});

// Gateway 1.7 records the calling Codex thread id on every call, so a worker a
// Codex Main opened lands on that Main's own local session with no transcript.
test("Gateway 1.7 names the Codex thread that opened a worker", () => {
  const thread = "019fd0e2-b481-7c82-bb18-06b120592a5a";
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: thread, state: "running", time: 100, cwd: "/repo" }
  ] });
  const main = local.sessions.find((session) => session.localSessionId === thread);
  const merged = mergeMonitorSessions([
    { sessionId: "acp-c", acpSessionId: "w-c", provider: "claude", status: "running",
      openedBy: { provider: "codex", sessionId: thread, pid: 9, instanceId: "mcp-c" } }
  ], local.sessions, new Map());
  const worker = merged.find((session) => session.sessionId === "acp-c");
  assert.equal(worker.parentSessionId, main.sessionId, "local:codex:<threadId> is the scanned Codex session");
  assert.equal(worker.openerInstanceId, main.openerInstanceId);
});

test("a Claude Main that switched sessions is found by its pid, not its stale id", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "claude", session: "after-clear", state: "running", time: 100, cwd: "/repo" }
  ] });
  const openedBy = { provider: "claude", sessionId: "before-clear", pid: 4242, instanceId: "mcp-a" };
  const merged = mergeMonitorSessions([
    { sessionId: "acp-1", acpSessionId: "w1", provider: "claude", status: "running", openedBy }
  ], local.sessions, new Map(), null, (caller) => (caller.pid === 4242 ? "after-clear" : null));
  const worker = merged.find((session) => session.sessionId === "acp-1");
  assert.equal(worker.parentSessionId, "local:claude:after-clear");
  assert.equal(worker.openerInstanceId, "after-clear");
});

test("one proven Codex worker attributes every worker its control instance opened", () => {
  const workerTopology = new Map();
  const codexCaller = { provider: "codex", sessionId: null, pid: 36864, instanceId: "mcp-codex-thread" };
  const linked = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "codex-thread", state: "running", time: 100, cwd: "/repo" },
    { provider: "claude", session: "worker-a", parent: "codex-thread", parent_provider: "codex", state: "running", time: 101, cwd: "/repo" }
  ] });
  const first = mergeMonitorSessions([
    { sessionId: "acp-a", acpSessionId: "worker-a", provider: "claude", status: "running", openedBy: codexCaller }
  ], linked.sessions, workerTopology);
  assert.equal(first[0].openerInstanceId, "codex-thread", "proven by the thread's own transcript");

  // A second worker the same thread opened, whose link never reached a transcript.
  const second = mergeMonitorSessions([
    { sessionId: "acp-b", acpSessionId: "worker-b", provider: "claude", status: "running", openedBy: codexCaller }
  ], [], workerTopology);
  assert.equal(second[0].openerInstanceId, "codex-thread");
  assert.equal(second[0].parentSessionId, "local:codex:codex-thread");
});

// Regression: idle local sessions now stay listed for the retention window,
// and a Gateway worker's own transcript outlives its Gateway session. Without
// remembering the worker, it came back as a parentless local session — a
// false Frontdoor — right after the delegation finished.
test("a worker the Gateway closed does not return as a local Frontdoor", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "ready", time: 100, cwd: "/repo" },
    { provider: "claude", session: "worker-uuid", state: "ready", time: 101, cwd: "/repo" }
  ] });
  const formerWorkerIds = new Set(["acp-1", "worker-uuid"]);
  const merged = mergeMonitorSessions([], local.sessions, new Map(), formerWorkerIds);
  assert.deepEqual(merged.map((session) => session.localSessionId), ["main"]);
  assert.deepEqual(merged.filter((session) => session.role === "frontdoor").map((session) => session.localSessionId), ["main"]);
});

test("a closed worker's own sub-agents do not come back as a Frontdoor either", () => {
  const local = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "main", state: "ready", time: 100, cwd: "/repo" },
    { provider: "codex", session: "worker-thread", state: "ready", time: 101, cwd: "/snapshot" },
    { provider: "codex", session: "worker-sub", state: "ready", time: 102, cwd: "/snapshot", parent: "worker-thread", parent_provider: "codex" },
    { provider: "codex", session: "worker-sub-sub", state: "ready", time: 103, cwd: "/snapshot", parent: "worker-sub", parent_provider: "codex" }
  ] });
  const merged = mergeMonitorSessions([], local.sessions, new Map(), new Set(["worker-thread"]));
  assert.deepEqual(merged.map((session) => session.localSessionId), ["main"]);
});

test("a session in a Gateway snapshot workspace with no parent is a worker's, not a Frontdoor", () => {
  const previous = process.env.ACP_GATEWAY_WORKSPACES;
  process.env.ACP_GATEWAY_WORKSPACES = "/ws-root";
  try {
    const local = projectLocalSnapshot({ sessions: [
      { provider: "codex", session: "main", state: "ready", time: 100, cwd: "/repo" },
      { provider: "codex", session: "stray", state: "ready", time: 101, cwd: "/ws-root/ws-1/tree" },
      { provider: "codex", session: "linked", state: "ready", time: 102, cwd: "/ws-root/ws-1/tree", parent: "main", parent_provider: "codex" }
    ] });
    const merged = mergeMonitorSessions([], local.sessions, new Map(), new Set());
    assert.deepEqual(merged.map((session) => session.localSessionId).sort(), ["linked", "main"], "a linked one stays under its parent");
    assert.equal(isMisrecordedWorker({ role: "frontdoor", source: "local", cwd: "/ws-root/ws-2/tree" }), true);
    assert.equal(isMisrecordedWorker({ role: "frontdoor", source: "local", cwd: "/repo" }), false);
  } finally {
    if (previous == null) delete process.env.ACP_GATEWAY_WORKSPACES;
    else process.env.ACP_GATEWAY_WORKSPACES = previous;
  }
});

test("sessions are named by the CLI's title, else their latest prompt, never an id", () => {
  const long = "please refactor the monitoring pipeline so every provider is normalized the same way";
  const projected = projectLocalSnapshot({ sessions: [
    { provider: "codex", session: "x", state: "running", time: 100 },
    { provider: "claude", session: "c", state: "running", time: 100 }
  ] }, new Map([
    ["codex:x", { events: [
      { kind: "turn_start", title: "first ask", ts: "2026-09-26T00:00:00Z" },
      { kind: "turn_start", title: long, ts: "2026-09-26T00:01:00Z" }
    ], session: {} }],
    ["claude:c", { events: [{ kind: "turn_start", title: "hi", ts: "2026-09-26T00:00:00Z" }], session: { title: "Monitoring refactor" } }]
  ]));
  const byId = new Map(projected.sessions.map((session) => [session.localSessionId, session]));
  assert.equal(byId.get("x").title, `${long.slice(0, 59)}…`, "the latest prompt, cut to a label");
  assert.equal(byId.get("c").title, "Monitoring refactor", "the CLI's own title wins");
});

test("a read-only Codex Gateway session carries the partial-policy warning", () => {
  const [codex, claude, open] = mergeMonitorSessions([
    { sessionId: "g1", provider: "codex", permissionPolicy: "read_only" },
    { sessionId: "g2", provider: "claude", permissionPolicy: "read_only" },
    { sessionId: "g3", provider: "codex", permissionPolicy: "auto_approve" }
  ], []);
  assert.equal(codex.alerts[0].code, "permission_policy_partial");
  assert.deepEqual(claude.alerts, []);
  assert.deepEqual(open.alerts, [], "auto_approve claims no restriction to weaken");
});

test("only changed or newly accepted local timelines are handed to the store", async () => {
  const { LocalEventDelivery } = await import("../src/local-monitor.js");
  const delivery = new LocalEventDelivery();
  const events = { "local:codex:a": [{ key: "1" }], "local:codex:b": [{ key: "2" }], "local:codex:w": [{ key: "3" }] };
  const accepted = new Set(["local:codex:a", "local:codex:b"]);
  assert.deepEqual(Object.keys(delivery.select(events, new Set(), accepted)), ["local:codex:a", "local:codex:b"], "first sight delivers every accepted window");
  assert.deepEqual(delivery.select(events, new Set(), accepted), {}, "an unchanged tick delivers nothing");
  assert.deepEqual(Object.keys(delivery.select(events, new Set(["local:codex:b"]), accepted)), ["local:codex:b"]);
  // A session accepted later (it stopped being a Gateway worker) is delivered once.
  accepted.add("local:codex:w");
  assert.deepEqual(Object.keys(delivery.select(events, new Set(), accepted)), ["local:codex:w"]);
  // One that left and came back is delivered again.
  delivery.select({ "local:codex:a": events["local:codex:a"] }, new Set(), accepted);
  assert.deepEqual(Object.keys(delivery.select(events, new Set(), accepted)), ["local:codex:b", "local:codex:w"]);
});
