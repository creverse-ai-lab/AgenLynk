import assert from "node:assert/strict";
import { appendFile, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { slimRecord } from "../src/local-agents/jsonl.js";
import { RecordTail } from "../src/local-agents/tail.js";
import { GatewayEventNormalizer, grokUsage, normalizeGrokUpdates } from "../src/normalize/acp.js";
import { ClaudeUsageAccumulator, normalizeClaudeRecords } from "../src/normalize/claude.js";
import { normalizeCodexRecords } from "../src/normalize/codex.js";
import { LocalTimeline } from "../src/normalize/local-timeline.js";
import { EVENT_KINDS, mergeEvent, monitorEvent } from "../src/normalize/model.js";
import { projectLocalSnapshot } from "../src/local-monitor.js";

// One logical turn — prompt, thought, message, one successful tool call, end —
// written the way each CLI writes it (shapes taken from real transcripts,
// content replaced).

const claudeTurn = [
  { type: "ai-title", aiTitle: "Inspect repo", sessionId: "c1" },
  { type: "user", uuid: "u1", promptId: "p1", timestamp: "2026-09-26T00:00:00.000Z", cwd: "/work", message: { role: "user", content: "inspect the repo" } },
  {
    type: "assistant", uuid: "a1", timestamp: "2026-09-26T00:00:01.000Z",
    message: {
      id: "msg_1", model: "claude-opus-5-5", content: [{ type: "thinking", thinking: "look at files" }],
      usage: { input_tokens: 2, cache_read_input_tokens: 100, cache_creation_input_tokens: 10, output_tokens: 5, output_tokens_details: { thinking_tokens: 3 } }
    }
  },
  {
    type: "assistant", uuid: "a2", timestamp: "2026-09-26T00:00:02.000Z",
    message: {
      id: "msg_1", model: "claude-opus-5-5", content: [{ type: "text", text: "Checking now." }],
      usage: { input_tokens: 2, cache_read_input_tokens: 100, cache_creation_input_tokens: 10, output_tokens: 5, output_tokens_details: { thinking_tokens: 3 } }
    }
  },
  {
    type: "assistant", uuid: "a3", timestamp: "2026-09-26T00:00:03.000Z",
    message: { id: "msg_2", model: "claude-opus-5-5", content: [{ type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "ls" } }], usage: { input_tokens: 1, cache_read_input_tokens: 200, cache_creation_input_tokens: 0, output_tokens: 7 } }
  },
  { type: "user", uuid: "u2", timestamp: "2026-09-26T00:00:04.000Z", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_1", content: "README.md", is_error: false }] } },
  { type: "system", subtype: "turn_duration", uuid: "s1", timestamp: "2026-09-26T00:00:05.000Z", durationMs: 5000 }
];

const codexTurn = [
  { timestamp: "2026-09-26T00:00:00.000Z", type: "session_meta", payload: { id: "x1", cwd: "/work" } },
  { timestamp: "2026-09-26T00:00:00.000Z", type: "event_msg", payload: { type: "task_started", turn_id: "t1", model_context_window: 258400 } },
  { timestamp: "2026-09-26T00:00:00.100Z", type: "turn_context", payload: { turn_id: "t1", model: "gpt-5.6-sol", cwd: "/work" } },
  { timestamp: "2026-09-26T00:00:00.200Z", type: "event_msg", payload: { type: "item_completed", turn_id: "t1", item: { type: "UserMessage", id: "um1", content: [{ type: "text", text: "inspect the repo" }] } } },
  { timestamp: "2026-09-26T00:00:01.000Z", type: "event_msg", payload: { type: "item_completed", turn_id: "t1", item: { type: "Reasoning", id: "rs1", summary_text: ["look at files"], raw_content: [] } } },
  { timestamp: "2026-09-26T00:00:02.000Z", type: "event_msg", payload: { type: "item_completed", turn_id: "t1", item: { type: "AgentMessage", id: "am1", content: [{ type: "Text", text: "Checking now." }] } } },
  { timestamp: "2026-09-26T00:00:03.000Z", type: "response_item", payload: { type: "function_call", name: "exec_command", call_id: "call_1", arguments: "{\"cmd\":\"ls\"}" } },
  { timestamp: "2026-09-26T00:00:04.000Z", type: "response_item", payload: { type: "function_call_output", call_id: "call_1", output: "README.md" } },
  {
    timestamp: "2026-09-26T00:00:04.500Z", type: "event_msg",
    payload: { type: "token_count", info: { total_token_usage: { input_tokens: 300, cached_input_tokens: 200, output_tokens: 12, reasoning_output_tokens: 3, total_tokens: 312 }, last_token_usage: { input_tokens: 201 }, model_context_window: 258400 } }
  },
  { timestamp: "2026-09-26T00:00:05.000Z", type: "event_msg", payload: { type: "task_complete", turn_id: "t1", duration_ms: 5000 } }
];

const grokUpdate = (seconds, update, meta = {}) => ({
  timestamp: 1790380800 + seconds,
  method: "session/update",
  params: { sessionId: "g1", update, _meta: { agentTimestampMs: (1790380800 + seconds) * 1000, ...meta } }
});
const grokTurn = [
  { timestamp: 1790380800, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "hook_execution", event_name: "user_prompt_submit", prompt_id: "p1" }, _meta: {} } },
  grokUpdate(0, { sessionUpdate: "user_message_chunk", content: { type: "text", text: "inspect the repo" }, _meta: { modelId: "grok-4.7" } }),
  grokUpdate(1, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "look at " } }, { promptId: "p1" }),
  grokUpdate(1, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "files" } }, { promptId: "p1" }),
  grokUpdate(2, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "Checking now." } }, { promptId: "p1" }),
  grokUpdate(3, { sessionUpdate: "tool_call", toolCallId: "call-1", title: "list_dir", rawInput: { target_directory: "/work" } }, { promptId: "p1" }),
  grokUpdate(4, { sessionUpdate: "tool_call_update", toolCallId: "call-1", status: "completed", content: [{ type: "content", content: { type: "text", text: "README.md" } }] }, { promptId: "p1" }),
  { timestamp: 1790380805, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "turn_completed", prompt_id: "p1", stop_reason: "end_turn", elapsed_ms: 5000 }, _meta: { agentTimestampMs: 1790380805000 } } }
];

const shape = (events) => events.map((event) => `${event.kind}${event.status ? `/${event.status}` : ""}`);

test("the same turn normalizes to the same timeline for Claude, Codex and Grok", () => {
  const expected = ["turn_start", "agent_thought", "agent_message", "tool_call/completed", "turn_end/completed"];
  const claude = normalizeClaudeRecords(claudeTurn);
  const codex = normalizeCodexRecords(codexTurn);
  const grok = normalizeGrokUpdates(grokTurn);
  assert.deepEqual(shape(claude.events), expected, "claude");
  assert.deepEqual(shape(codex.events), expected, "codex");
  assert.deepEqual(shape(grok.events), expected, "grok");

  for (const result of [claude, codex, grok]) {
    const [start, thought, message, tool] = result.events;
    assert.equal(start.body, "inspect the repo", "the prompt opens the turn");
    assert.match(thought.body, /look at ?files/);
    assert.equal(message.body, "Checking now.");
    assert.equal(tool.body, "README.md", "tool output lands on the same event as the call");
    assert.ok(tool.endedAt, "a finished tool call records when it ended");
    assert.ok(result.events.every((event) => event.turnId === start.turnId), "every event belongs to the turn");
    assert.ok(result.events.every((event) => EVENT_KINDS.includes(event.kind)));
    assert.equal(result.session.status, "idle", "a completed turn leaves the session idle");
  }
  assert.equal(claude.session.model, "claude-opus-5-5");
  assert.equal(claude.session.title, "Inspect repo");
  assert.equal(codex.session.model, "gpt-5.6-sol");
  assert.equal(grok.session.model, "grok-4.7");
});

test("usage has one meaning across providers: input includes cache, total = input + output", () => {
  const accumulator = new ClaudeUsageAccumulator();
  for (const record of claudeTurn) accumulator.add(record);
  const claude = accumulator.totals();
  // msg_1 appears on two records with the same usage and counts once.
  assert.equal(claude.inputTokens, 2 + 100 + 10 + 1 + 200);
  assert.equal(claude.outputTokens, 12);
  assert.equal(claude.totalTokens, claude.inputTokens + claude.outputTokens);
  assert.equal(normalizeClaudeRecords(claudeTurn).session.usage.contextUsed, 201, "context is the latest call's prompt");

  const codex = normalizeCodexRecords(codexTurn).session.usage;
  assert.equal(codex.inputTokens, 300);
  assert.equal(codex.cacheReadTokens, 200);
  assert.equal(codex.totalTokens, 312);
  assert.equal(codex.contextUsed, 201);
  assert.equal(codex.contextWindow, 258400);

  const grok = grokUsage(
    { session: { inputTokens: 300, outputTokens: 12, cachedReadTokens: 200, reasoningTokens: 3, totalTokens: 312, costUsdTicks: 5_000_000_000, primaryModelId: "grok-4.7-build" } },
    { contextTokensUsed: 201, contextWindowTokens: 500000 }
  );
  assert.equal(grok.usage.totalTokens, 312);
  assert.equal(grok.usage.costUsd, 0.5);
  assert.equal(grok.usage.contextWindow, 500000);
  assert.equal(grok.model, "grok-4.7-build");
});

test("re-normalizing a window is stable, so the store never duplicates", () => {
  const first = normalizeClaudeRecords(claudeTurn).events.map((event) => event.key);
  const again = normalizeClaudeRecords(claudeTurn).events.map((event) => event.key);
  assert.deepEqual(first, again);
  // A window that has slid past the prompt keeps the same keys for what remains.
  const slid = normalizeClaudeRecords(claudeTurn.slice(3)).events.map((event) => event.key);
  assert.ok(slid.every((key) => first.includes(key)));
});

test("Claude skips slash-command bookkeeping and keeps subagent lines apart", () => {
  const records = [
    { type: "user", uuid: "c", timestamp: "2026-09-26T00:00:00Z", message: { content: "<command-name>/model</command-name>" } },
    { type: "user", uuid: "o", timestamp: "2026-09-26T00:00:00Z", message: { content: "<local-command-stdout>Set model</local-command-stdout>" } },
    { type: "user", uuid: "m", timestamp: "2026-09-26T00:00:01Z", message: { content: "main prompt" } },
    { type: "user", uuid: "s", isSidechain: true, agentId: "agent-1", timestamp: "2026-09-26T00:00:02Z", message: { content: "sub prompt" } }
  ];
  assert.deepEqual(normalizeClaudeRecords(records).events.map((event) => event.body), ["main prompt"]);
  assert.deepEqual(normalizeClaudeRecords(records, { agentId: "agent-1" }).events.map((event) => event.body), ["sub prompt"]);
});

test("an interrupted Claude turn and an aborted Codex turn both end cancelled", () => {
  const claude = normalizeClaudeRecords([
    claudeTurn[1],
    { type: "user", uuid: "i", timestamp: "2026-09-26T00:00:09Z", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } }
  ]);
  assert.deepEqual(shape(claude.events), ["turn_start", "turn_end/cancelled"]);
  const codex = normalizeCodexRecords([
    codexTurn[1],
    { timestamp: "2026-09-26T00:00:09Z", type: "event_msg", payload: { type: "turn_aborted", turn_id: "t1", reason: "interrupted" } }
  ]);
  assert.deepEqual(shape(codex.events), ["turn_start", "turn_end/cancelled"]);
});

test("Grok subagents become one subagent event that completes", () => {
  const result = normalizeGrokUpdates([
    grokTurn[1],
    { timestamp: 1790380801, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "subagent_spawned", child_session_id: "child-1", description: "review", subagent_type: "reviewer", model: "grok-4.6" }, _meta: { promptId: "p1" } } },
    { timestamp: 1790380802, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "subagent_finished", child_session_id: "child-1", status: "completed", output: "done", tokens_used: 42 }, _meta: { promptId: "p1" } } }
  ]);
  const subagent = result.events.find((event) => event.kind === "subagent");
  assert.equal(subagent.status, "completed");
  assert.equal(subagent.body, "done");
  assert.equal(subagent.detail.childSessionId, "child-1");
  assert.equal(subagent.detail.tokensUsed, 42);
});

test("Gateway permission requests resolve in place and chunks read in daemon order", () => {
  const normalizer = new GatewayEventNormalizer();
  const options = [{ optionId: "yes", kind: "allow_once", name: "Allow" }, { optionId: "no", kind: "reject_once", name: "Reject" }];
  const ask = (sequence, requestId) => normalizer.ingest({ sessionId: "s", sequence, type: "permission_request", ts: "2026-09-26T00:00:00Z", turnId: "t", requestId, toolCall: { toolCallId: "c1", title: "Write file" }, options })[0];
  const answer = (sequence, requestId, optionId) => normalizer.ingest({ sessionId: "s", sequence, type: "permission_response", ts: "2026-09-26T00:00:01Z", turnId: "t", requestId, optionId })[0];
  const request = ask(1, 1);
  assert.equal(request.kind, "permission_request");
  assert.equal(request.status, "pending");
  const allowed = answer(2, 1, "yes");
  assert.equal(allowed.key, request.key);
  assert.deepEqual([mergeEvent(request, allowed).status, allowed.detail.outcome], ["completed", "approved"]);
  ask(3, 2);
  assert.deepEqual([answer(4, 2, "no").status, answer(4, 2, "no").detail.outcome], ["failed", "denied"], "a rejected option is a denial");
  ask(5, 3);
  assert.equal(answer(6, 3, null).detail.outcome, "cancelled", "no option chosen is a cancellation");

  const chunks = new GatewayEventNormalizer();
  chunks.ingest({ sessionId: "s", sequence: 5, type: "agent_message_chunk", ts: "2026-09-26T00:00:05Z", turnId: "t", text: "world" });
  const [message] = chunks.ingest({ sessionId: "s", sequence: 4, type: "agent_message_chunk", ts: "2026-09-26T00:00:04Z", turnId: "t", text: "hello " });
  assert.equal(message.body, "hello world");
});

test("a terminal event status never regresses and sources accumulate", () => {
  const done = monitorEvent({ key: "tool:1", kind: "tool_call", ts: "2026-09-26T00:00:02Z", source: "transcript", status: "completed" });
  const lateHook = monitorEvent({ key: "tool:1", kind: "tool_call", ts: "2026-09-26T00:00:01Z", source: "hook", status: "running" });
  const merged = mergeEvent(done, lateHook);
  assert.equal(merged.status, "completed");
  assert.equal(merged.ts, "2026-09-26T00:00:01.000Z", "the earliest sighting is when it started");
  assert.deepEqual(merged.sources, ["transcript", "hook"]);
});

async function withTempDirectory(run) {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-normalize-"));
  try {
    return await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

test("RecordTail reads appended lines once, adopts large files from the tail, and restarts on rewrite", async () => {
  await withTempDirectory(async (root) => {
    const path = join(root, "t.jsonl");
    const seen = [];
    const tail = new RecordTail(path, { onRecord: (record) => seen.push(record.n), adoptionTailBytes: 64 });
    await writeFile(path, `${JSON.stringify({ n: 1, timestamp: new Date().toISOString() })}\n`);
    assert.equal(await tail.poll(), true);
    await appendFile(path, `${JSON.stringify({ n: 2, timestamp: new Date().toISOString() })}\n{"n":3`);
    await tail.poll();
    assert.deepEqual(seen, [1, 2], "a partial last line waits for its newline");
    await appendFile(path, "}\n");
    await tail.poll();
    assert.deepEqual(seen, [1, 2, 3]);

    await writeFile(path, `${JSON.stringify({ n: 9 })}\n`);
    await tail.poll();
    assert.deepEqual(tail.records.map((record) => record.n), [9], "a shrunken file is read from the start");

    const big = join(root, "big.jsonl");
    await writeFile(big, `${Array.from({ length: 20 }, (_, n) => JSON.stringify({ n })).join("\n")}\n`);
    const adopted = new RecordTail(big, { adoptionTailBytes: 64 });
    await adopted.poll();
    assert.equal(adopted.adoptedFromTail, true);
    assert.ok(adopted.records.length < 20 && adopted.records.at(-1).n === 19, "only the tail is adopted");
  });
});

test("LocalTimeline tails Claude and Grok sessions and reuses the Codex window", async () => {
  await withTempDirectory(async (root) => {
    const claudePath = join(root, "c1.jsonl");
    await writeFile(claudePath, claudeTurn.slice(0, 3).map((record) => JSON.stringify(record)).join("\n") + "\n");
    const grokDirectory = join(root, "grok", "g1");
    await mkdir(grokDirectory, { recursive: true });
    await writeFile(join(grokDirectory, "updates.jsonl"), grokTurn.map((record) => JSON.stringify(record)).join("\n") + "\n");
    await writeFile(join(grokDirectory, "usage.json"), JSON.stringify({ session: { inputTokens: 10, outputTokens: 2, totalTokens: 12 } }));

    const timeline = new LocalTimeline({ codexRecords: (id) => (id === "x1" ? codexTurn : []) });
    const sessions = [
      { provider: "claude", session: "c1", transcript: claudePath },
      { provider: "grok", session: "g1", transcript: grokDirectory },
      { provider: "codex", session: "x1" }
    ];
    const first = await timeline.update(sessions, Date.parse("2026-09-26T00:10:00Z"));
    assert.deepEqual([...first.changed].sort(), ["claude:c1", "codex:x1", "grok:g1"]);
    assert.equal(first.results.get("grok:g1").session.usage.totalTokens, 12);
    assert.deepEqual(shape(first.results.get("claude:c1").events), ["turn_start", "agent_thought"]);

    const quiet = await timeline.update(sessions, Date.parse("2026-09-26T00:10:01Z"));
    assert.equal(quiet.changed.size, 0, "nothing changed on disk, nothing is re-normalized");

    await appendFile(claudePath, claudeTurn.slice(3).map((record) => JSON.stringify(record)).join("\n") + "\n");
    const grown = await timeline.update(sessions, Date.parse("2026-09-26T00:10:02Z"));
    assert.deepEqual([...grown.changed], ["claude:c1"]);
    assert.deepEqual(shape(grown.results.get("claude:c1").events), ["turn_start", "agent_thought", "agent_message", "tool_call/completed", "turn_end/completed"]);
    assert.equal(grown.results.get("claude:c1").session.usage.outputTokens, 12);
  });
});

test("a Gateway turn comes from the Main that prompted it and its end goes back", () => {
  const normalizer = new GatewayEventNormalizer();
  const promptedBy = { provider: "claude", sessionId: "main-uuid", pid: 4242, instanceId: "mcp-a" };
  const [start] = normalizer.ingest({ type: "turn_start", turnId: "turn-1", ts: "2026-09-28T00:00:00Z", promptedBy });
  assert.equal(start.from, "local:claude:main-uuid");
  const [end] = normalizer.ingest({ type: "turn_end", turnId: "turn-1", ts: "2026-09-28T00:00:05Z", stopReason: "end_turn" });
  assert.equal(end.to, "local:claude:main-uuid");

  const codex = new GatewayEventNormalizer();
  const [codexStart] = codex.ingest({
    type: "turn_start", turnId: "turn-2", ts: "2026-09-28T00:01:00Z",
    promptedBy: { provider: "codex", sessionId: null, pid: 36864, instanceId: "mcp-codex" }
  });
  assert.equal(codexStart.from, "caller:mcp-codex", "no thread id: the control instance");

  const legacy = new GatewayEventNormalizer();
  const [legacyStart] = legacy.ingest({ type: "turn_start", turnId: "turn-3", ts: "2026-09-28T00:02:00Z" });
  assert.equal("from" in legacyStart, false, "a pre-1.6 Gateway proves nothing, so nothing is claimed");
});

test("a grok -p run is headless by Grok's own session summary", async () => {
  await withTempDirectory(async (root) => {
    const directory = join(root, "grok", "g1");
    await mkdir(directory, { recursive: true });
    await writeFile(join(directory, "updates.jsonl"), grokTurn.map((record) => JSON.stringify(record)).join("\n") + "\n");
    const timeline = new LocalTimeline();
    const raw = { provider: "grok", session: "g1", transcript: directory, state: "ready", time: 1 };
    const before = await timeline.update([raw], Date.parse("2026-09-26T00:10:00Z"));
    assert.equal(before.results.get("grok:g1").session.headless, undefined, "no summary, no claim");

    await writeFile(join(directory, "summary.json"), JSON.stringify({ info: { id: "g1" }, session_kind: "headless" }));
    const after = await timeline.update([raw], Date.parse("2026-09-26T00:10:01Z"));
    assert.deepEqual([...after.changed], ["grok:g1"], "a new summary alone refreshes the facts");
    assert.equal(after.results.get("grok:g1").session.headless, true);
    // Projected even when process lineage never saw the (already exited) process.
    const [session] = projectLocalSnapshot({ sessions: [raw] }, after.results).sessions;
    assert.equal(session.headless, true);

    await writeFile(join(directory, "summary.json"), JSON.stringify({ info: { id: "g1" }, session_kind: "subagent" }));
    const interactive = await timeline.update([raw], Date.parse("2026-09-26T00:10:02Z"));
    assert.equal(interactive.results.get("grok:g1").session.headless, undefined);
    assert.equal(projectLocalSnapshot({ sessions: [raw] }, interactive.results).sessions[0].headless, undefined);
  });
});

test("an SDK-launched Claude is a Frontdoor when a person is driving it", () => {
  const raw = { provider: "claude", session: "c1", state: "ready", time: 1, headless: true };
  const prompt = (ts) => ({ kind: "user_message", ts });
  const project = (session, events = [prompt("2026-09-28T00:00:00Z")]) =>
    projectLocalSnapshot({ sessions: [session] }, new Map([["claude:c1", { events, session: {} }]])).sessions[0];

  const oneShot = project(raw);
  assert.equal(oneShot.role, "worker", "an unlaunched one-shot run is an unattributed Worker");
  assert.equal(oneShot.openerInstanceId, null);
  assert.equal(oneShot.headless, true);

  const hosted = project({ ...raw, interactive: true });
  assert.equal(hosted.role, "frontdoor", "a chat host that asks a person for permission");
  assert.equal(hosted.openerInstanceId, "c1");
  assert.equal(hosted.headless, undefined);

  const conversed = project(raw, [prompt("2026-09-28T00:00:00Z"), prompt("2026-09-28T00:01:00Z")]);
  assert.equal(conversed.role, "frontdoor", "more than one prompt is a conversation");
  assert.equal(conversed.headless, undefined);
});

test("a turn that ends closes the tool calls it left open, for every source", () => {
  const claude = normalizeClaudeRecords([
    claudeTurn[1],
    claudeTurn[4],
    { type: "user", uuid: "i", timestamp: "2026-09-26T00:00:09Z", message: { content: [{ type: "text", text: "[Request interrupted by user]" }] } }
  ]);
  assert.equal(claude.events.find((event) => event.kind === "tool_call").status, "cancelled");

  const codex = normalizeCodexRecords([
    codexTurn[1], codexTurn[6],
    { timestamp: "2026-09-26T00:00:09Z", type: "event_msg", payload: { type: "turn_aborted", turn_id: "t1" } }
  ]);
  assert.equal(codex.events.find((event) => event.kind === "tool_call").status, "cancelled");

  const grok = normalizeGrokUpdates([
    grokTurn[1], grokTurn[5],
    { timestamp: 1790380809, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "turn_completed", prompt_id: "p1", stop_reason: "cancelled" }, _meta: {} } }
  ]);
  assert.equal(grok.events.find((event) => event.kind === "tool_call").status, "cancelled");

  const gateway = new GatewayEventNormalizer();
  gateway.ingest({ sessionId: "s", sequence: 1, type: "tool_call", ts: "2026-09-26T00:00:01Z", turnId: "t", data: { sessionUpdate: "tool_call", toolCallId: "c1", title: "Read" } });
  const closed = gateway.ingest({ sessionId: "s", sequence: 2, type: "turn_completed", ts: "2026-09-26T00:00:02Z", turnId: "t", stopReason: "end_turn" });
  assert.equal(closed.find((event) => event.key === "tool:c1")?.status, "completed");
});

test("every provider reports per-turn token use for the forecast", () => {
  const claude = normalizeClaudeRecords(claudeTurn).session.turns;
  // msg_1 (2 records, counted once: 112 in + 5 out) + msg_2 (201 in + 7 out)
  assert.deepEqual(claude.map((turn) => [turn.running, turn.totalTokens, turn.outputTokens, turn.contextUsed]), [[false, 325, 12, 201]]);

  const codex = normalizeCodexRecords(codexTurn).session.turns;
  assert.equal(codex.length, 1);
  assert.equal(codex[0].running, false);
  assert.equal(codex[0].outputTokens, 12);

  const grok = normalizeGrokUpdates([
    ...grokTurn.slice(0, -1),
    { timestamp: 1790380805, method: "_x.ai/session/update", params: { sessionId: "g1", update: { sessionUpdate: "turn_completed", prompt_id: "p1", stop_reason: "end_turn", usage: { totalTokens: 900, outputTokens: 40 } }, _meta: {} } }
  ]).session.turns;
  assert.deepEqual(grok.map((turn) => [turn.running, turn.totalTokens, turn.outputTokens]), [[false, 900, 40]]);

  const running = normalizeGrokUpdates(grokTurn.slice(0, -1)).session.turns;
  assert.equal(running[0].running, true);
  assert.equal(running[0].totalTokens, null, "Grok settles a turn's tokens only when it ends");
});

test("slimmed window records normalize to the same events as the originals", () => {
  const huge = `line one\n${"y".repeat(100_000)}`;
  const records = [
    { type: "user", timestamp: "2026-08-07T00:00:00.000Z", uuid: "u1", message: { role: "user", content: [{ type: "text", text: huge }] } },
    { type: "assistant", timestamp: "2026-08-07T00:00:01.000Z", uuid: "a1", message: { id: "m1", role: "assistant", content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: huge } }] } },
    { type: "user", timestamp: "2026-08-07T00:00:02.000Z", uuid: "u2", toolUseResult: { stdout: huge, stderr: "" }, message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: huge }] } }
  ];
  const slimmed = records.map((record) => slimRecord(record));
  assert.ok(JSON.stringify(slimmed).length < JSON.stringify(records).length / 5);
  assert.deepEqual(normalizeClaudeRecords(slimmed), normalizeClaudeRecords(records));
  const small = { type: "user", message: { content: "short" } };
  assert.equal(slimRecord(small), small, "a record with nothing to cut is returned as is");
});

test("RecordTail keeps a character budget whatever the record count", async () => {
  await withTempDirectory(async (root) => {
    const path = join(root, "t.jsonl");
    const now = Date.now();
    await writeFile(path, `${Array.from({ length: 10 }, (_, n) => JSON.stringify({ n, timestamp: new Date(now).toISOString(), pad: "z".repeat(1_000) })).join("\n")}\n`);
    const tail = new RecordTail(path, { maxChars: 3_500 });
    await tail.poll(now);
    assert.deepEqual(tail.records.map((record) => record.n), [7, 8, 9]);
    assert.ok(tail.chars <= 3_500);
  });
});

test("Claude usage totals survive folding old message ids", () => {
  const assistant = (id, input, output) => ({ type: "assistant", message: { id, usage: { input_tokens: input, output_tokens: output } } });
  const bounded = new ClaudeUsageAccumulator({ openMessageLimit: 2 });
  const unbounded = new ClaudeUsageAccumulator({ openMessageLimit: Infinity });
  for (const record of [assistant("m1", 1, 1), assistant("m1", 1, 2), assistant("m2", 5, 5), assistant("m3", 7, 1), assistant("m4", 2, 2), assistant("m4", 2, 3)]) {
    bounded.add(record);
    unbounded.add(record);
  }
  assert.ok(bounded.byMessage.size <= 2);
  assert.deepEqual(bounded.totals(), unbounded.totals());
});
