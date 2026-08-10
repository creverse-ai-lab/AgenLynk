import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { detectClaudeSessions } from "../src/local-agents/claude.js";
import { discover, poll, prune } from "../src/local-agents/codex.js";
import { cliProcessStates, recordGrokAcpLinks } from "../src/local-agents/grok.js";
import { detectOrcaSessions } from "../src/local-agents/orca.js";
import {
  externalParent,
  linkKey,
  pruneExternalParents,
  recordExternalParent
} from "../src/local-agents/parent-links.js";
import { signalFor, signalWithApprovals } from "../src/local-agents/signals.js";
import { snapshotSessions, stateRecord } from "../src/local-agents/snapshot.js";
import { withReadOnlyDatabase } from "../src/local-agents/sqlite.js";

// These mirror the Python watcher's self_test so the port can be checked
// against the behaviour it replaces rather than against itself.

async function withTempDirectory(run) {
  const root = await mkdtemp(join(tmpdir(), "acp-local-agents-"));
  try {
    return await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

async function createCodexDatabase(path, rows) {
  const { DatabaseSync } = await import("node:sqlite");
  const database = new DatabaseSync(path);
  database.exec("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)");
  database.exec(
    "CREATE TABLE threads (id TEXT, model TEXT, model_provider TEXT, cwd TEXT, thread_source TEXT, rollout_path TEXT, updated_at INTEGER)"
  );
  for (const edge of rows.edges ?? []) {
    database.prepare("INSERT INTO thread_spawn_edges VALUES (?, ?)").run(edge.parent, edge.child);
  }
  for (const thread of rows.threads ?? []) {
    database.prepare("INSERT INTO threads VALUES (?, ?, ?, ?, ?, ?, ?)").run(
      thread.id, thread.model, thread.provider ?? "codex", thread.cwd,
      thread.source ?? "user", thread.rolloutPath ?? null, thread.updatedAt ?? 0
    );
  }
  database.close();
}

test("codex transcript records classify into running/ready/needs_input states", () => {
  assert.deepEqual(
    signalFor({ type: "event_msg", payload: { type: "task_started" } }),
    ["running", "task_started"]
  );
  assert.deepEqual(
    signalFor({ type: "response_item", payload: { type: "function_call", name: "request_user_input" } }),
    ["needs_input", "function_call/request_user_input"]
  );
  assert.equal(signalFor({ type: "event_msg", payload: { type: "unknown" } }), null);
});

test("an unresolved approval overrides the transcript state until it is answered", () => {
  const pending = new Set();
  assert.deepEqual(
    signalWithApprovals({
      type: "response_item",
      payload: {
        type: "custom_tool_call",
        name: "exec",
        call_id: "approval-one",
        input: 'sandbox_permissions: "require_escalated"'
      }
    }, pending),
    ["needs_input", "approval/pending"]
  );
  assert.deepEqual(
    signalWithApprovals({
      type: "response_item",
      payload: { type: "custom_tool_call_output", call_id: "approval-one" }
    }, pending),
    ["running", "approval/resolved"]
  );
  assert.equal(pending.size, 0);

  // ACP permission traffic nests arbitrarily deep inside a tool result.
  assert.deepEqual(
    signalWithApprovals({
      type: "event_msg",
      payload: { result: { events: [{ type: "permission_request", requestId: 7 }] } }
    }, pending),
    ["needs_input", "approval/pending"]
  );
  assert.deepEqual(
    signalWithApprovals({
      type: "event_msg",
      payload: { result: { events: [{ type: "permission_response", requestId: 7, optionId: "allow" }] } }
    }, pending),
    ["running", "approval/resolved"]
  );
  assert.equal(pending.size, 0);

  // A finished turn clears anything still outstanding.
  const stuck = new Set(["acp:9"]);
  assert.deepEqual(
    signalWithApprovals({ type: "event_msg", payload: { type: "task_complete" } }, stuck),
    ["ready", "task_complete"]
  );
  assert.equal(stuck.size, 0);
});

test("gateway parenthood is claimed only from proven tool responses", () => {
  const parents = new Map();
  const now = 100;
  recordExternalParent({
    type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      invocation: { server: "grok-acp" },
      result: { acpSessionId: "grok-session" }
    }
  }, "one", parents, now);
  assert.equal(externalParent(parents, "grok", "grok-session"), "one");

  // The generic "agent-acp" server name means the provider must come from the
  // response body itself.
  recordExternalParent({
    type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      invocation: { server: "agent-acp" },
      result: {
        content: [{
          type: "text",
          text: JSON.stringify({ ok: true, sessionId: "acp-7", acpSessionId: "gw-77", provider: "grok" })
        }]
      }
    }
  }, "one", parents, now);
  assert.equal(externalParent(parents, "grok", "gw-77"), "one");

  // A record that is not a gateway tool call claims nothing.
  const untrusted = new Map();
  recordExternalParent({
    type: "event_msg",
    payload: { type: "agent_message", result: { acpSessionId: "leak-1", provider: "grok", ok: true } }
  }, "one", untrusted, now);
  assert.equal(untrusted.size, 0);
});

test("stale parent links are dropped once their worker is no longer active", () => {
  const parents = new Map([
    [linkKey("grok", "grok-session"), ["grok-cli-10", 100]],
    [linkKey("claude", "gone"), ["orchestrator", 100]]
  ]);
  pruneExternalParents(parents, {
    grok: { provider: "grok", session: "grok-cli-10", link_session: "grok-session" }
  }, 1, 200);
  assert.ok(parents.has(linkKey("grok", "grok-session")), "an active worker keeps its link");
  assert.ok(!parents.has(linkKey("claude", "gone")), "an inactive stale link is dropped");
});

test("a grok CLI session adopts the gateway workers its own log proves it opened", async () => {
  await withTempDirectory(async (root) => {
    const grokRoot = join(root, "grok-sessions");
    const sessionDirectory = join(grokRoot, "%2Fwork", "grok-session");
    await mkdir(sessionDirectory, { recursive: true });
    await writeFile(join(sessionDirectory, "updates.jsonl"), [
      JSON.stringify({
        update: {
          rawOutput: {
            tool_name: "agent_acp_session_open",
            server_name: "agent-acp",
            output: { OkayOutput: JSON.stringify({ ok: true, acpSessionId: "worker-1", provider: "claude" }) }
          }
        }
      }),
      // Quoted gateway output with no tool_name must not create a link.
      JSON.stringify({
        update: { content: JSON.stringify({ ok: true, acpSessionId: "worker-echo", provider: "claude" }) }
      })
    ].join("\n") + "\n");

    const parents = new Map();
    const states = {
      "grok-cli-10": {
        provider: "grok", session: "grok-cli-10", state: "running",
        link_session: "grok-session", parent: null
      }
    };
    assert.equal(await recordGrokAcpLinks(states, parents, 100, grokRoot), true);
    assert.equal(externalParent(parents, "claude", "worker-1"), "grok-session");
    assert.equal(externalParent(parents, "claude", "worker-echo"), null);

    // The link is recorded against the provider-side id; the snapshot must
    // resolve it to the id it actually exposes for that session.
    const remapped = await snapshotSessions({
      "grok-cli-10": { ...states["grok-cli-10"], engine: "grok-cli", cwd: "/work" },
      "worker-1": {
        provider: "claude", session: "worker-1", state: "running", parent: "grok-session",
        engine: "claude-acp", cwd: "/work", delegated: true, link_session: "worker-1"
      }
    });
    assert.equal(remapped.find((item) => item.session === "worker-1").parent, "grok-cli-10");
  });
});

test("a grok process is only reported while its transcript shows an open turn", async () => {
  await withTempDirectory(async (root) => {
    const active = join(root, "%2Fwork", "grok-session", "events.jsonl");
    await mkdir(join(root, "%2Fwork", "grok-session"), { recursive: true });
    await writeFile(active, '{"type":"turn_started"}\n{"type":"phase_changed"}\n');
    const ended = join(root, "ended-events.jsonl");
    await writeFile(ended, '{"type":"turn_started"}\n{"type":"turn_ended"}\n');

    const processes = new Map([
      [10, [1, "/Users/test/.g", "/Users/test/.grok/bin/grok"]],
      [11, [1, "/usr/local/bin/grok", "grok"]],
      // A grok launched through the ACP proxy is a gateway worker, not local.
      [20, [21, "/usr/local/bin/grok", "grok agent stdio"]],
      [21, [1, "python3", "python3 pet_acp_proxy.py --provider grok"]]
    ]);
    const eventPaths = new Map([[10, active], [11, ended], [20, active]]);
    const parents = new Map([[linkKey("grok", "grok-session"), ["one", 100]]]);

    const states = await cliProcessStates(processes, eventPaths, 100, {}, parents);
    assert.deepEqual(Object.keys(states), ["grok-cli-10"]);
    assert.equal(states["grok-cli-10"].parent, "one");
    assert.equal(states["grok-cli-10"].cwd, "/work", "the session directory encodes the cwd");
    assert.equal(states["grok-cli-10"].link_session, "grok-session");
  });
});

test("claude transcripts yield state, expire on their own lifetime, and cache by fingerprint", async () => {
  await withTempDirectory(async (root) => {
    const claude = join(root, "claude");
    await mkdir(claude, { recursive: true });
    const transcript = join(claude, "claude-session.jsonl");
    const now = Date.now() / 1000;
    const timestamp = new Date((now - 2) * 1000).toISOString();
    const parents = new Map([[linkKey("claude", "claude-session"), ["one", now]]]);

    await writeFile(transcript, JSON.stringify({
      type: "assistant",
      sessionId: "claude-session",
      timestamp,
      message: { stop_reason: "end_turn", content: [{ type: "text" }] }
    }) + "\n");
    const ready = await detectClaudeSessions(claude, now, 5, 600, parents);
    assert.equal(ready["claude-session"].state, "ready");
    assert.equal(ready["claude-session"].parent, "one");
    // A finished turn only lingers for readyAfter seconds.
    assert.deepEqual(await detectClaudeSessions(claude, now + 4, 5, 600, parents), {});

    await writeFile(transcript, JSON.stringify({
      type: "user",
      sessionId: "claude-session",
      timestamp,
      message: { content: [{ type: "tool_result" }] }
    }) + "\n");
    assert.equal((await detectClaudeSessions(claude, now, 5, 600, parents))["claude-session"].state, "running");
    // A running turn is considered stale much sooner than staleAfter.
    assert.deepEqual(await detectClaudeSessions(claude, now + 29, 5, 600, parents), {});

    const cache = new Map();
    assert.equal((await detectClaudeSessions(claude, now, 5, 600, parents, cache))["claude-session"].state, "running");
    assert.deepEqual([...cache.keys()], [transcript]);

    // A cached entry is trusted while the fingerprint matches...
    const { fingerprint, signal } = cache.get(transcript);
    cache.set(transcript, { fingerprint, signal: { ...signal, event: "cached" } });
    assert.equal((await detectClaudeSessions(claude, now, 5, 600, parents, cache))["claude-session"].event, "cached");

    // ...and re-read once the file changes underneath it.
    await utimes(transcript, new Date(), new Date(Date.now() + 1000));
    cache.set(transcript, { fingerprint, signal: { ...signal, event: "cached" } });
    assert.equal((await detectClaudeSessions(claude, now, 5, 600, parents, cache))["claude-session"].event, "user");

    await rm(transcript);
    assert.deepEqual(await detectClaudeSessions(claude, now, 5, 600, parents, cache), {});
    assert.equal(cache.size, 0, "a deleted transcript drops out of the cache");
  });
});

test("only mcpMeta.structuredContent can make a claude session a parent", async () => {
  await withTempDirectory(async (root) => {
    const claude = join(root, "link-claude");
    await mkdir(claude, { recursive: true });
    const now = Date.now() / 1000;
    const timestamp = new Date((now - 1) * 1000).toISOString();

    await writeFile(join(claude, "orchestrator.jsonl"), JSON.stringify({
      type: "user",
      sessionId: "orchestrator",
      timestamp,
      mcpMeta: { structuredContent: { ok: true, sessionId: "acp-1", acpSessionId: "gw-grok", provider: "grok" } },
      message: { content: [{ type: "tool_result", content: [{ type: "text", text: "ok" }] }] }
    }) + "\n");

    // Text that merely LOOKS like a gateway response — a session echoing
    // gateway output while debugging — must not claim parenthood.
    const echo = JSON.stringify({ ok: true, acpSessionId: "leak-1", provider: "grok" });
    await writeFile(join(claude, "auditor.jsonl"), JSON.stringify({
      type: "user",
      sessionId: "auditor",
      timestamp,
      toolUseResult: { stdout: echo },
      message: { content: [{ type: "tool_result", content: [{ type: "text", text: echo }] }] }
    }) + "\n");

    // A session cannot adopt itself.
    await writeFile(join(claude, "selfy.jsonl"), JSON.stringify({
      type: "user",
      sessionId: "selfy",
      timestamp,
      mcpMeta: { structuredContent: { ok: true, acpSessionId: "selfy", provider: "claude" } },
      message: { content: [{ type: "tool_result", content: [{ type: "text", text: "ok" }] }] }
    }) + "\n");

    const parents = new Map();
    const detected = await detectClaudeSessions(claude, now, 5, 600, parents);
    assert.equal(detected.orchestrator.state, "running");
    assert.equal(externalParent(parents, "grok", "gw-grok"), "orchestrator");
    assert.equal(externalParent(parents, "grok", "leak-1"), null);
    assert.equal(externalParent(parents, "claude", "selfy"), null);
  });
});

test("orca panes map to states and expire by their own lifetime", async () => {
  await withTempDirectory(async (root) => {
    const status = join(root, "orca-status.json");
    const now = Date.now() / 1000;
    await writeFile(status, JSON.stringify({
      entries: {
        "grok-pane": {
          worktreeId: "repo::/orca",
          providerSession: { id: "orca-grok" },
          payload: { agentType: "grok", state: "working" },
          receivedAt: now * 1000
        },
        "claude-pane": {
          worktreeId: "repo::/orca",
          providerSession: { id: "orca-claude" },
          payload: { agentType: "claude", state: "done" },
          receivedAt: now * 1000
        }
      }
    }));
    const detected = await detectOrcaSessions(status, now, 3, 600);
    assert.equal(detected["orca-grok"].state, "running");
    assert.equal(detected["orca-grok"].cwd, "/orca");
    assert.equal(detected["orca-claude"].state, "ready");
    assert.ok(!(await detectOrcaSessions(status, now + 4, 3, 600))["orca-claude"], "a done pane expires");
  });
});

test("codex cursors tail transcripts incrementally and identify the real session id", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await mkdir(sessions, { recursive: true });
    const transcript = join(sessions, "rollout-one.jsonl");
    await writeFile(transcript, [
      '{"type":"session_meta","payload":{"id":"one"}}',
      '{"type":"event_msg","payload":{"type":"task_started"}}'
    ].join("\n") + "\n");

    const cursors = new Map();
    const retired = new Map();
    const states = {};
    const parents = new Map();
    const now = Date.now() / 1000;

    await discover({ root: sessions, cursors, retired, staleAfter: 600, now, database: null });
    assert.equal(cursors.size, 1, "a fresh transcript is picked up");
    await poll({ cursors, states, parents, now });
    assert.equal(states.one.state, "running", "the session_meta id replaces the filename stem");

    // Appending is read incrementally; the cursor never rewinds.
    const offsetAfterFirst = cursors.get(transcript).offset;
    await writeFile(transcript, [
      '{"type":"session_meta","payload":{"id":"one"}}',
      '{"type":"event_msg","payload":{"type":"task_started"}}',
      '{"type":"event_msg","payload":{"type":"task_complete"}}'
    ].join("\n") + "\n");
    await poll({ cursors, states, parents, now });
    assert.equal(states.one.state, "ready");
    assert.ok(cursors.get(transcript).offset > offsetAfterFirst, "the cursor advanced");

    // A half-written last line must not be consumed.
    const before = cursors.get(transcript).offset;
    await writeFile(transcript, [
      '{"type":"session_meta","payload":{"id":"one"}}',
      '{"type":"event_msg","payload":{"type":"task_started"}}',
      '{"type":"event_msg","payload":{"type":"task_complete"}}',
      '{"type":"event_msg","payload":{"type":"task_st'
    ].join("\n"));
    await poll({ cursors, states, parents, now });
    assert.equal(cursors.get(transcript).offset, before, "a partial line is left for the next poll");

    // A finished transcript is retired once readyAfter passes, and stays in
    // `retired` until it too goes stale, so it is not rediscovered every scan.
    prune({ cursors, states, retired, readyAfter: 1, staleAfter: 5, now: now + 3 });
    assert.equal(cursors.size, 0, "a quiet transcript is retired");
    assert.ok(retired.has(transcript), "the retired mtime is remembered");
    prune({ cursors, states, retired, readyAfter: 1, staleAfter: 5, now: now + 20 });
    assert.equal(retired.size, 0, "a long-dead transcript stops being tracked at all");
  });
});

test("codex thread database supplies engine, cwd, spawn edges and sub-agent parents", async () => {
  await withTempDirectory(async (root) => {
    const database = join(root, "state.sqlite");
    await createCodexDatabase(database, {
      edges: [{ parent: "one", child: "two" }],
      threads: [
        { id: "one", model: "gpt-main", cwd: "/work", source: "user" },
        { id: "two", model: "gpt-child", cwd: "/work", source: "subagent" },
        { id: "review", model: "codex-auto-review", cwd: "/work", source: "subagent" },
        { id: "lonely", model: "gpt-lonely", cwd: "/solo", source: "subagent" },
        { id: "gwcodex", model: "gpt-worker", cwd: "/gw", source: "user" }
      ]
    });

    const now = Date.now() / 1000;
    // "one" has finished, so only "two" is a live adoption candidate in /work.
    const sessions = await snapshotSessions({
      one: stateRecord("one", "ready", "task_complete", now),
      two: stateRecord("two", "running", "task_started", now),
      review: stateRecord("review", "running", "review", now + 1),
      lonely: stateRecord("lonely", "running", "task_started", now + 1),
      external: {
        provider: "grok", session: "external", state: "running",
        parent: null, engine: "grok-cli", cwd: "/work"
      }
    }, database);

    const find = (id) => sessions.find((item) => item.session === id);
    assert.equal(find("two").parent, "one", "a spawn edge wins");
    assert.equal(find("two").engine, "gpt-child", "the engine comes from the database");
    // The same-cwd fallback only adopts into an active session in that cwd.
    assert.equal(find("external").parent, "two");
    assert.equal(find("review").parent, "two");
    assert.equal(find("lonely").parent, null, "nothing is running in /solo");
  });
});

test("the same-cwd fallback never re-parents an orchestrator under its own worker", async () => {
  await withTempDirectory(async (root) => {
    const database = join(root, "state.sqlite");
    await createCodexDatabase(database, {
      threads: [{ id: "gwcodex", model: "gpt-worker", cwd: "/gw", source: "user" }]
    });
    const sessions = await snapshotSessions({
      orch: {
        provider: "claude", session: "orch", state: "running",
        parent: null, engine: "claude-cli", cwd: "/gw", time: 50
      },
      gwcodex: {
        provider: "codex", session: "gwcodex", state: "running",
        parent: "orch", engine: "codex-acp", cwd: "/gw", time: 60
      }
    }, database);
    const find = (id) => sessions.find((item) => item.session === id);
    assert.equal(find("gwcodex").parent, "orch");
    assert.equal(find("gwcodex").engine, "gpt-worker");
    assert.equal(find("orch").parent, null, "the reverse edge would be a cycle");
  });
});

test("a missing or malformed codex database degrades to status-only sessions", async () => {
  await withTempDirectory(async (root) => {
    const now = Date.now() / 1000;
    const missing = await snapshotSessions(
      { one: stateRecord("one", "running", "task_started", now) },
      join(root, "does-not-exist.sqlite")
    );
    assert.equal(missing.length, 1);
    assert.equal(missing[0].session, "one");
    assert.equal(missing[0].parent, null);

    const garbage = join(root, "garbage.sqlite");
    await writeFile(garbage, "not a database");
    const degraded = await snapshotSessions(
      { one: stateRecord("one", "running", "task_started", now) },
      garbage
    );
    assert.equal(degraded.length, 1, "a corrupt database must not take the monitor down");
    assert.equal(degraded[0].parent, null, "no spawn edges can be read from garbage");
    // Any failure inside the reader resolves to the caller's fallback rather
    // than propagating out of the scanner.
    assert.equal(
      await withReadOnlyDatabase(garbage, () => { throw new Error("boom"); }, "fallback"),
      "fallback"
    );
  });
});

test("reversed reading survives multibyte characters straddling chunk boundaries", async () => {
  await withTempDirectory(async (root) => {
    const { reversedRecords } = await import("../src/local-agents/jsonl.js");
    const path = join(root, "multibyte.jsonl");
    // Enough Korean text that 64KB chunk boundaries are guaranteed to land
    // inside multibyte sequences, many times over.
    const lines = [];
    for (let index = 0; index < 200; index += 1) {
      lines.push(JSON.stringify({ index, text: "한글 트랜스크립트 내용 ".repeat(60) }));
    }
    await writeFile(path, lines.join("\n") + "\n");

    const seen = [];
    for await (const record of reversedRecords(path)) seen.push(record.index);
    assert.equal(seen.length, 200, "no record may be dropped by a boundary-corrupted decode");
    assert.deepEqual(seen, [...Array(200).keys()].reverse(), "records arrive newest-first, all intact");
  });
});

test("codex cursor advances by bytes so multibyte transcripts do not re-parse forever", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await mkdir(sessions, { recursive: true });
    const transcript = join(sessions, "rollout-kr.jsonl");
    const koreanLine = JSON.stringify({
      type: "event_msg",
      payload: { type: "task_started" },
      text: "한국어 프롬프트 내용입니다 ".repeat(20)
    });
    const content = '{"type":"session_meta","payload":{"id":"kr"}}\n' + koreanLine + "\n";
    await writeFile(transcript, content);

    const cursors = new Map();
    const retired = new Map();
    const states = {};
    const parents = new Map();
    const now = Date.now() / 1000;
    await discover({ root: sessions, cursors, retired, staleAfter: 600, now, database: null });
    await poll({ cursors, states, parents, now });
    assert.equal(
      cursors.get(transcript).offset,
      Buffer.byteLength(content, "utf8"),
      "the cursor must land on the byte length, not the character count"
    );
    // With the cursor converged, an unchanged file reports no change.
    assert.equal(await poll({ cursors, states, parents, now }), false, "a converged cursor stays quiet");
  });
});

test("a transcript atomically replaced with same-sized content is re-read", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await mkdir(sessions, { recursive: true });
    const transcript = join(sessions, "rollout-swap.jsonl");
    // The trailing space pads "task_started" to the byte length of
    // "task_complete"; JSON.parse ignores surrounding whitespace.
    const first = '{"type":"session_meta","payload":{"id":"aa"}}\n{"type":"event_msg","payload":{"type":"task_started"}} \n';
    await writeFile(transcript, first);

    const cursors = new Map();
    const retired = new Map();
    const states = {};
    const parents = new Map();
    const now = Date.now() / 1000;
    await discover({ root: sessions, cursors, retired, staleAfter: 600, now, database: null });
    await poll({ cursors, states, parents, now });
    assert.equal(states.aa.state, "running");

    // Same byte length, different content and mtime — the size check alone
    // would never notice this.
    const second = '{"type":"session_meta","payload":{"id":"aa"}}\n{"type":"event_msg","payload":{"type":"task_complete"}}\n';
    assert.equal(Buffer.byteLength(second), Buffer.byteLength(first), "fixture must keep sizes identical");
    await writeFile(transcript, second);
    await utimes(transcript, new Date(), new Date(Date.now() + 2000));
    await poll({ cursors, states, parents, now });
    assert.equal(states.aa.state, "ready", "the rewrite must be picked up despite the unchanged size");
  });
});
