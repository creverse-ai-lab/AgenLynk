import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { HookSessions } from "../src/hooks/registry.js";
import { LocalAgentScanner } from "../src/local-agents/index.js";
import {
  annotateExecLineage,
  annotateLineage,
  headlessArgs,
  interactiveHostArgs,
  hookLineageHeaders,
  lineageMarkers,
  markerParent,
  parseLsofCwds,
  parseProcessTable,
  ProcessLineage
} from "../src/local-agents/lineage.js";
import { mergeMonitorSessions, projectLocalSnapshot } from "../src/local-monitor.js";

const CLAUDE_ID = "625cbd07-50b1-4ffa-b0bd-368891bb5085";
const GROK_ID = "01a0e05b-19af-7fd3-b6af-473e5c9d372f";
const START = "Sat Sep 26 03:48:14 2026";

async function withTempDirectory(run) {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-lineage-"));
  try {
    return await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

/**
 * A fake `ps`: `processes` maps pid -> { ppid, comm, args, env }. No real
 * process is ever inspected.
 */
function fakePs(processes) {
  const calls = [];
  const run = async (command, args) => {
    calls.push(args.join(" "));
    assert.equal(command, "ps");
    if (args[0] === "-axo") {
      return Object.entries(processes)
        .map(([pid, item]) => `${pid} ${item.ppid} ${item.start ?? START} ${item.comm}`).join("\n");
    }
    const pid = args.at(-1);
    const item = processes[pid];
    if (!item) return "";
    if (args[0] === "eww") return `${item.args}${item.env ? ` ${item.env}` : ""}\n`;
    if (args[0] === "ww") return `${item.args}\n`;
    return "";
  };
  return { run, calls };
}

async function claudePidFile(directory, pid, sessionId, extra = {}) {
  await mkdir(directory, { recursive: true });
  await writeFile(join(directory, `${pid}.json`), JSON.stringify({
    pid, sessionId, procStart: START, startedAt: Date.parse(`${START} GMT`) + 2_000, kind: "interactive", entrypoint: "cli", ...extra
  }));
}

test("lineage markers come only from the environment part, in the id charset", () => {
  const args = "grok -p review CLAUDE_CODE_SESSION_ID=from-the-prompt";
  assert.deepEqual(lineageMarkers(`${args} PATH=/bin CLAUDE_CODE_SESSION_ID=${CLAUDE_ID} SECRET=x GROK_SESSION_ID=g1\n`, `${args}\n`), {
    claude: CLAUDE_ID,
    grok: "g1"
  });
  assert.deepEqual(lineageMarkers(`${args} PATH=/bin\n`, `${args}\n`), {}, "a marker inside the args is not one");
  assert.deepEqual(lineageMarkers("other CLAUDE_CODE_SESSION_ID=a", "grok"), {}, "a mismatched args prefix reads nothing");
  assert.deepEqual(lineageMarkers("codex exec CODEX_THREAD_ID=a CODEX_THREAD_ID=b", "codex exec"), {}, "conflicting values are ambiguous");
  assert.deepEqual(lineageMarkers("codex CODEX_THREAD_ID=a;rm", "codex"), {}, "values outside the charset are dropped");
  assert.deepEqual(lineageMarkers("claude CLAUDE_CODE_ENTRYPOINT=cli", "claude"), {}, "only the three session ids are read");
});

test("hook lineage headers are validated like environment markers", () => {
  assert.deepEqual(hookLineageHeaders({
    "x-agenlynk-parent-claude": CLAUDE_ID,
    "x-agenlynk-parent-grok": "bad value",
    "x-agenlynk-entrypoint": "sdk-cli",
    "x-agenlynk-hook-ppid": "4242"
  }), { markers: { claude: CLAUDE_ID, entrypoint: "sdk-cli" }, ppid: 4242 });
  assert.deepEqual(hookLineageHeaders({ "x-agenlynk-hook-ppid": "1" }), { markers: {}, ppid: null });
  assert.equal(markerParent({ claude: "c", grok: "g" }, { provider: "grok", session: "g" }).session, "c", "own id is not a parent");
  assert.equal(markerParent({ claude: "c", grok: "g" }, { provider: "codex", session: "x" }), null, "two launchers are ambiguous");
  assert.equal(markerParent({ claude: "c" }, { provider: "claude", session: "c" }), null);
});

test("headless flags are read from the command line only", () => {
  assert.equal(headlessArgs("grok", "grok -p review this"), true);
  assert.equal(headlessArgs("grok", "/Users/x/.grok/bin/grok --single=hi"), true);
  assert.equal(headlessArgs("grok", "grok"), false);
  assert.equal(headlessArgs("claude", "claude -p hi"), true);
  assert.equal(headlessArgs("claude", "claude --resume"), false);
  assert.equal(headlessArgs("codex", "codex exec -s read-only"), true);
  const hosted = "/Users/x/.local/bin/claude --output-format stream-json --input-format stream-json --permission-prompt-tool stdio";
  assert.equal(interactiveHostArgs("claude", hosted), true, "a chat host relays permission prompts to a person");
  assert.equal(interactiveHostArgs("claude", "claude --permission-prompt-tool=stdio"), true);
  assert.equal(interactiveHostArgs("claude", "claude -p hi --permission-prompt-tool mcp__auth__ok"), false, "an MCP tool answers, not a person");
  assert.equal(interactiveHostArgs("claude", "claude -p hi"), false);
  assert.equal(interactiveHostArgs("grok", "grok --permission-prompt-tool stdio"), false);
  assert.equal(parseProcessTable(`  16964 15448 ${START}     claude\n`).get(16964).comm, "claude");
});

test("a grok run from a Claude Code Bash tool is that Claude session's worker", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 16964, CLAUDE_ID);
    const { run, calls } = fakePs({
      1: { ppid: 0, comm: "/sbin/launchd", args: "/sbin/launchd" },
      15448: { ppid: 1, comm: "/bin/zsh", args: "-zsh" },
      16964: { ppid: 15448, comm: "claude", args: "claude", env: "CLAUDE_CODE_SESSION_ID=older-outer" },
      4860: { ppid: 16964, comm: "/bin/zsh", args: "/bin/zsh -c grok -p review" },
      4866: {
        ppid: 4860,
        comm: "grok",
        args: "grok -p review",
        env: `HOME=/x CLAUDE_CODE_SESSION_ID=${CLAUDE_ID} CLAUDE_PID=16964 OPENAI_API_KEY=sk-no`
      }
    });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    await lineage.refresh(100);
    assert.equal(lineage.claudePidForSession(CLAUDE_ID), 16964);
    const resolved = await lineage.resolve(4866, { provider: "grok", session: GROK_ID });
    assert.deepEqual(resolved, { parent: { provider: "claude", session: CLAUDE_ID }, headless: true });

    const psCalls = calls.length;
    await lineage.resolve(4866, { provider: "grok", session: GROK_ID });
    assert.equal(calls.length, psCalls, "resolved once per process");

    // A marker naming the process's own session (no agent ancestor to
    // disambiguate) is not a parent.
    const own = await lineage.resolve(16964, { provider: "claude", session: "older-outer" });
    assert.equal(own.parent, null, "an own-session marker is not a parent");
  });
});

test("a nested claude -p finds its launcher through the pid chain, and the Gateway stops the walk", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 100, "outer");
    await claudePidFile(sessions, 300, "inner", { entrypoint: "sdk-cli" });
    const { run } = fakePs({
      100: { ppid: 1, comm: "claude", args: "claude" },
      200: { ppid: 100, comm: "/bin/zsh", args: "zsh -c claude -p x" },
      // No marker in the child's env: the pid chain alone names the launcher.
      300: { ppid: 200, comm: "claude", args: "claude -p x" },
      400: { ppid: 1, comm: "/Users/x/.acp-gateway/runtime/versions/1.5.2/node/bin/node", args: "node daemon" },
      500: { ppid: 400, comm: "claude", args: "claude", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}` }
    });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    await lineage.refresh(100);
    assert.deepEqual((await lineage.resolve(300, { provider: "claude", session: "inner" })).parent, { provider: "claude", session: "outer" });
    assert.equal((await lineage.resolve(500, { provider: "claude", session: "gw" })).parent, null,
      "a Gateway worker's parent is the Gateway's to say, whatever env the daemon carries");

    const items = [
      { provider: "claude", session: "inner", pid: null },
      { provider: "claude", session: "outer", pid: null },
      { provider: "grok", session: "proven", pid: 300, parent: "mcp-parent" }
    ];
    await annotateLineage(items, lineage, 100);
    assert.equal(items[0].parent, "outer");
    assert.equal(items[0].parent_provider, "claude");
    assert.equal(items[0].parent_source, "lineage");
    assert.equal(items[0].headless, true, "Claude's pid file says sdk-cli");
    assert.equal(items[1].parent, undefined, "an interactive root stays a root");
    assert.equal(items[2].parent, "mcp-parent", "a proven link is never replaced");
    assert.equal(items[2].parent_source, undefined);
  });
});

test("a reused Claude pid is not the session its old pid file names", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 100, "gone", { procStart: "Mon Sep 21 01:00:00 2026", startedAt: Date.parse("2026-09-21T01:00:02Z") });
    const { run } = fakePs({ 100: { ppid: 1, comm: "claude", args: "claude" } });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    await lineage.refresh(100);
    assert.equal(lineage.claudePidForSession("gone"), null);
  });
});

test("lineage projects a shell-launched agent as a worker of its launcher", () => {
  const { sessions } = projectLocalSnapshot({
    sessions: [
      { provider: "grok", session: GROK_ID, state: "running", time: 10, parent: CLAUDE_ID, parent_provider: "claude", parent_source: "lineage", headless: true },
      { provider: "codex", session: "solo", state: "running", time: 10, headless: true }
    ]
  });
  const grok = sessions.find((session) => session.localSessionId === GROK_ID);
  assert.equal(grok.role, "worker");
  assert.equal(grok.parentSessionId, `local:claude:${CLAUDE_ID}`, "the provider lineage proved names the parent even when it is not listed");
  assert.equal(grok.opener, "claude");
  assert.equal(grok.openerInstanceId, CLAUDE_ID);
  assert.equal(grok.headless, true);
  assert.equal(grok.parentProof, "lineage");
  const solo = sessions.find((session) => session.localSessionId === "solo");
  assert.equal(solo.role, "worker", "unparented headless work is kept, but never as a Frontdoor");
  assert.equal(solo.openerInstanceId, null, "it lands in the unattributed Worker group");
  assert.equal(solo.headless, true);

  const merged = mergeMonitorSessions(
    [{ sessionId: "gw-1", acpSessionId: GROK_ID, provider: "grok", status: "running" }],
    sessions,
    new Map()
  );
  const gateway = merged.find((session) => session.sessionId === "gw-1");
  assert.equal(gateway.openerInstanceId, undefined, "lineage never attributes a Gateway worker");
  assert.equal(merged.some((session) => session.localSessionId === GROK_ID && session.source === "local"), false);
});

test("a hook-only session with no activity is held back, then dropped, even with a transcript", async () => {
  await withTempDirectory(async (root) => {
    const claudeRoot = join(root, "projects");
    const registry = new HookSessions({ claudeRoot, grokRoot: join(root, "grok"), isAlive: () => true });
    const at = Date.parse("2026-09-27T01:01:49Z");
    const probe = { session_id: "probe-1", cwd: "/Users/x/Library/Application Support/CodexBar/ClaudeProbe", transcript_path: join(claudeRoot, "p", "probe-1.jsonl") };

    const started = registry.record("claude", { ...probe, hook_event_name: "SessionStart" }, at);
    assert.equal(started.heldBack, true);
    assert.deepEqual(registry.merge([], at), [], "an empty probe run is not listed");
    const ended = registry.record("claude", { ...probe, hook_event_name: "SessionEnd" }, at + 500);
    assert.equal(ended.heldBack, true, "its session_end is not stored either");
    assert.deepEqual(registry.merge([], at + 500), []);
    assert.equal(registry.sessions.size, 0, "and it is forgotten at its end");

    // One that never ends is forgotten after a short TTL.
    registry.record("claude", { ...probe, session_id: "probe-2", hook_event_name: "SessionStart" }, at);
    registry.merge([], at + 60_000);
    assert.equal(registry.sessions.size, 1);
    registry.merge([], at + 3 * 60_000);
    assert.equal(registry.sessions.size, 0);

    // Real activity lists it normally.
    registry.record("claude", { ...probe, session_id: "real", hook_event_name: "SessionStart" }, at);
    assert.deepEqual(registry.merge([], at), []);
    const prompted = registry.record("claude", { ...probe, session_id: "real", hook_event_name: "UserPromptSubmit" }, at + 1_000);
    assert.equal(prompted.heldBack, false);
    assert.equal(registry.merge([], at + 1_000).find((raw) => raw.session === "real")?.state, "running");

    // A transcript on disk is no proof: a probe writes one and deletes it.
    // A real resumed session is listed by the scanner instead (below).
    await mkdir(join(claudeRoot, "p"), { recursive: true });
    await writeFile(join(claudeRoot, "p", "resumed.jsonl"), "{}\n");
    const resumed = registry.record("claude", {
      ...probe, session_id: "resumed", transcript_path: join(claudeRoot, "p", "resumed.jsonl"), hook_event_name: "SessionStart"
    }, at);
    assert.equal(resumed.heldBack, true);
    assert.ok(!registry.merge([], at).some((raw) => raw.session === "resumed"));

    // The scanner seeing a transcript lists it whatever the hooks said.
    registry.record("codex", { session_id: "scanned", hook_event_name: "SessionStart" }, at);
    assert.ok(registry.merge([{ provider: "codex", session: "scanned", state: "ready", time: at / 1000 }], at)
      .some((raw) => raw.session === "scanned"));
  });
});

test("hook lineage makes a shell-launched session a worker; the scanner's proven parent wins", async () => {
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 16964, CLAUDE_ID);
    const { run } = fakePs({
      16964: { ppid: 1, comm: "claude", args: "claude" },
      4860: { ppid: 16964, comm: "/bin/zsh", args: "zsh -c grok -p x" },
      4866: { ppid: 4860, comm: "grok", args: "grok -p x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}` },
      4900: { ppid: 4866, comm: "/bin/sh", args: "sh -c hook" }
    });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    const registry = new HookSessions({ claudeRoot: join(root, "projects"), grokRoot: join(root, "grok"), isAlive: () => true });
    const at = Date.parse("2026-09-27T01:00:00Z");

    const recorded = registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: GROK_ID, cwd: "/w" }, at,
      { markers: { claude: CLAUDE_ID }, ppid: 4900 });
    await registry.resolveLineage(recorded.key, lineage, at);
    const [raw] = registry.merge([], at);
    assert.equal(raw.parent, CLAUDE_ID);
    assert.equal(raw.parent_provider, "claude");
    assert.equal(raw.headless, true, "grok -p is a one-shot run");
    assert.equal(projectLocalSnapshot({ sessions: [raw] }).sessions[0].role, "worker");

    // No process found (e.g. it already exited): the forwarded markers stand in.
    const other = registry.record("codex", { hook_event_name: "UserPromptSubmit", session_id: "cx" }, at,
      { markers: { claude: CLAUDE_ID, entrypoint: "cli" }, ppid: 99999 });
    await registry.resolveLineage(other.key, lineage, at);
    const scanned = registry.merge([{ provider: "codex", session: "cx", state: "running", time: 0, parent: "mcp-proven" }], at);
    assert.equal(scanned.find((item) => item.session === "cx").parent, "mcp-proven", "a scanner-proven parent wins");
    assert.equal(registry.merge([], at).find((item) => item.session === "cx").parent, CLAUDE_ID);

    // A Claude hook whose marker is its own session has no parent.
    const self = registry.record("claude", { hook_event_name: "UserPromptSubmit", session_id: CLAUDE_ID }, at,
      { markers: { claude: CLAUDE_ID }, ppid: null });
    await registry.resolveLineage(self.key, null, at);
    assert.equal(registry.merge([], at).find((item) => item.session === CLAUDE_ID).parent, null);
  });
});

const CODEX_ID = "01a0e0b5-39b5-7672-b16d-de8cf6c4f752";
// 2026-09-26T03:48:14Z, the fake processes' START.
const START_SECONDS = Date.parse(`${START} GMT`) / 1000;

/** fakePs plus a fake `lsof -a -d cwd -p <pids> -Fn`: `cwd` per process. */
function fakePsLsof(processes) {
  const ps = fakePs(processes);
  const lsofCalls = [];
  const run = async (command, args) => {
    if (command !== "lsof") return ps.run(command, args);
    lsofCalls.push(args.join(" "));
    assert.deepEqual(args.slice(0, 4), ["-a", "-d", "cwd", "-p"]);
    return args[4].split(",")
      .filter((pid) => processes[pid]?.cwd)
      .map((pid) => `p${pid}\nfcwd\nn${processes[pid].cwd}`).join("\n");
  };
  return { run, calls: ps.calls, lsofCalls };
}

test("a codex exec thread is matched to its process by cwd and start time", async () => {
  assert.deepEqual([...parseLsofCwds("p12\nfcwd\nn/w\np13\nfcwd\n")], [[12, "/w"]]);
  await withTempDirectory(async (root) => {
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 16964, CLAUDE_ID);
    const { run, lsofCalls } = fakePsLsof({
      16964: { ppid: 1, comm: "claude", args: "claude" },
      4860: { ppid: 16964, comm: "/bin/zsh", args: "zsh -c codex exec x" },
      4870: { ppid: 4860, comm: "codex", args: "codex exec x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" },
      // Interactive codex elsewhere, same second: another cwd is no match.
      5000: { ppid: 1, comm: "codex", args: "codex", cwd: "/other" },
      // Same cwd, but started long before the thread.
      5100: { ppid: 1, comm: "codex", args: "codex exec y", cwd: "/w", start: "Sat Sep 26 03:40:00 2026" }
    });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    const cursor = { session: CODEX_ID, exec: { createdAt: START_SECONDS + 2, cwd: "/w" } };
    const cursors = new Map([["rollout", cursor]]);
    await annotateExecLineage(cursors, lineage, START_SECONDS + 3);
    assert.deepEqual(cursor.exec.parent, { provider: "claude", session: CLAUDE_ID });
    assert.equal(cursor.exec.done, true);
    assert.deepEqual(lsofCalls, ["-a -d cwd -p 4870,5000 -Fn"], "only codex processes started near the thread are looked at");
    await annotateExecLineage(cursors, lineage, START_SECONDS + 4);
    assert.equal(lsofCalls.length, 1, "a resolved thread is not matched again");

    // Two exec runs in one folder at once: which is which is unknown, but a
    // launcher they share is still their parent; different launchers are not.
    const twin = new ProcessLineage({ claudeSessionsDir: sessions, run: fakePsLsof({
      4870: { ppid: 1, comm: "codex", args: "codex exec x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" },
      4871: { ppid: 1, comm: "codex", args: "codex exec y", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" }
    }).run });
    await twin.refresh(START_SECONDS + 3);
    assert.deepEqual(await twin.codexExecPid({ cwd: "/w", createdAt: START_SECONDS }), { pid: null, final: true, ambiguous: [4870, 4871] });
    const twinCursor = { session: "t", exec: { createdAt: START_SECONDS, cwd: "/w" } };
    await annotateExecLineage(new Map([["t", twinCursor]]), twin, START_SECONDS + 3);
    assert.deepEqual(twinCursor.exec.parent, { provider: "claude", session: CLAUDE_ID }, "a shared launcher is the parent");
    const split = new ProcessLineage({ claudeSessionsDir: sessions, run: fakePsLsof({
      4870: { ppid: 1, comm: "codex", args: "codex exec x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" },
      4871: { ppid: 1, comm: "codex", args: "codex exec y", env: "GROK_SESSION_ID=other-grok", cwd: "/w" }
    }).run });
    await split.refresh(START_SECONDS + 3);
    const splitCursor = { session: "s", exec: { createdAt: START_SECONDS, cwd: "/w" } };
    await annotateExecLineage(new Map([["s", splitCursor]]), split, START_SECONDS + 3);
    assert.equal(splitCursor.exec.parent, undefined, "different launchers stay unattributed");

    // An interactive codex is not a `codex exec` run, whatever it matches.
    const interactive = { session: "i", exec: { createdAt: START_SECONDS, cwd: "/w" } };
    await annotateExecLineage(new Map([["r", interactive]]), new ProcessLineage({ claudeSessionsDir: sessions, run: fakePsLsof({
      4870: { ppid: 1, comm: "codex", args: "codex", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" }
    }).run }), START_SECONDS + 3);
    assert.equal(interactive.exec.parent, undefined);

    // No process yet within the window: asked again; after it: given up.
    const gone = new ProcessLineage({ claudeSessionsDir: sessions, run: fakePsLsof({ 1: { ppid: 0, comm: "launchd", args: "launchd" } }).run });
    await gone.refresh(START_SECONDS + 5);
    assert.deepEqual(await gone.codexExecPid({ cwd: "/w", createdAt: START_SECONDS }), { pid: null, final: false });
    await gone.refresh(START_SECONDS + 60, { force: true });
    assert.deepEqual(await gone.codexExecPid({ cwd: "/w", createdAt: START_SECONDS }), { pid: null, final: true });
  });
});

test("the scanner keeps a codex exec thread's lineage parent after the process exits", async () => {
  await withTempDirectory(async (root) => {
    const codexSessions = join(root, "codex-sessions");
    const rollout = join(codexSessions, "2026", `rollout-2026-09-26T03-48-16-${CODEX_ID}.jsonl`);
    await mkdir(join(codexSessions, "2026"), { recursive: true });
    await writeFile(rollout, `{"type":"session_meta","payload":{"id":"${CODEX_ID}"}}\n{"type":"event_msg","payload":{"type":"task_started"}}\n`);
    const database = join(root, "state_5.sqlite");
    const { DatabaseSync } = await import("node:sqlite");
    const db = new DatabaseSync(database);
    db.exec("CREATE TABLE thread_spawn_edges (parent_thread_id TEXT, child_thread_id TEXT)");
    db.exec("CREATE TABLE threads (id TEXT, rollout_path TEXT, created_at INTEGER, updated_at INTEGER, source TEXT, model TEXT, model_provider TEXT, cwd TEXT, thread_source TEXT)");
    const now = START_SECONDS + 3;
    db.prepare("INSERT INTO threads VALUES (?, ?, ?, ?, 'exec', 'gpt', 'openai', '/w', 'user')").run(CODEX_ID, rollout, START_SECONDS + 2, now);
    db.close();

    const claudeSessions = join(root, "claude-sessions");
    await claudePidFile(claudeSessions, 16964, CLAUDE_ID);
    const processes = {
      16964: { ppid: 1, comm: "claude", args: "claude" },
      4860: { ppid: 16964, comm: "/bin/zsh", args: "zsh -c codex exec x" },
      4870: { ppid: 4860, comm: "codex", args: "codex exec x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}`, cwd: "/w" }
    };
    const scanner = new LocalAgentScanner({
      sessionsRoot: codexSessions,
      database,
      claudeRoot: join(root, "projects"),
      grokRoot: join(root, "grok"),
      orcaAccounts: null,
      orcaStatus: join(root, "orca.json"),
      lineage: new ProcessLineage({ claudeSessionsDir: claudeSessions, run: fakePsLsof(processes).run })
    });
    // Keep the real process scan (grok) out of this test.
    scanner.lastProcessScan = Number.POSITIVE_INFINITY;
    const [first] = await scanner.scan(now);
    assert.equal(first.session, CODEX_ID);
    assert.equal(first.parent, CLAUDE_ID);
    assert.equal(first.parent_provider, "claude");
    assert.equal(first.parent_source, "lineage");
    assert.equal(first.headless, true);
    const projected = projectLocalSnapshot({ sessions: [first] }).sessions[0];
    assert.equal(projected.role, "worker");
    assert.equal(projected.parentSessionId, `local:claude:${CLAUDE_ID}`);
    assert.equal(projected.parentProof, "lineage");

    delete processes[4870];
    delete processes[4860];
    const [later] = await scanner.scan(now + 30);
    assert.equal(later.parent, CLAUDE_ID, "the parent outlives the process");
  });
});

test("a proven codex parent beats a codex exec lineage parent", async () => {
  const { snapshotSessions } = await import("../src/local-agents/snapshot.js");
  const [item] = await snapshotSessions({
    x: { provider: "codex", session: "x", state: "running", time: 1, pid: null, lineage_parent: { provider: "claude", session: "c" } }
  });
  assert.equal(item.parent, "c");
  assert.equal(item.parent_source, "lineage");
  assert.equal(item.lineage_parent, undefined);
  const [proven] = await snapshotSessions({
    x: { provider: "codex", session: "x", state: "running", time: 1, pid: null, parent: "mcp", lineage_parent: { provider: "claude", session: "c" } }
  });
  assert.equal(proven.parent, "mcp");
  assert.equal(proven.parent_source, undefined);
});

const GROK_PARENT_ID = "01a0e12f-cc46-7f10-85c7-4552b92ec473";
const GROK_CHILD_ID = "01a0e12f-f6dc-7292-833a-fefdfcd67baf";

/** Grok's layout for a `spawn_subagent`: the child sits next to its parent, which records it. */
async function grokSubagentLayout(grokRoot, cwd, { meta = true } = {}) {
  const workspace = join(grokRoot, encodeURIComponent(cwd));
  const record = join(workspace, GROK_PARENT_ID, "subagents", GROK_CHILD_ID);
  await mkdir(record, { recursive: true });
  if (meta) {
    await writeFile(join(record, "meta.json"), JSON.stringify({
      subagent_id: GROK_CHILD_ID, parent_session_id: GROK_PARENT_ID, child_session_id: GROK_CHILD_ID, status: "completed"
    }));
  }
  await mkdir(join(workspace, GROK_CHILD_ID), { recursive: true });
  await writeFile(join(workspace, GROK_CHILD_ID, "summary.json"), JSON.stringify({ session_kind: "subagent" }));
  return workspace;
}

test("a grok sub-agent's parent is the grok session that spawned it, not its process lineage", async () => {
  await withTempDirectory(async (root) => {
    const grokRoot = join(root, "grok");
    await grokSubagentLayout(grokRoot, "/w");
    const sessions = join(root, "sessions");
    await claudePidFile(sessions, 16964, CLAUDE_ID);
    // The sub-agent runs inside its parent's `grok -p`, so its hooks carry
    // the same process chain and the same CLAUDE_CODE_SESSION_ID.
    const { run } = fakePs({
      16964: { ppid: 1, comm: "claude", args: "claude" },
      4860: { ppid: 16964, comm: "/bin/zsh", args: "zsh -c grok -p x" },
      4866: { ppid: 4860, comm: "grok", args: "grok -p x", env: `CLAUDE_CODE_SESSION_ID=${CLAUDE_ID}` },
      4900: { ppid: 4866, comm: "/bin/sh", args: "sh -c hook" }
    });
    const lineage = new ProcessLineage({ claudeSessionsDir: sessions, run });
    const registry = new HookSessions({ claudeRoot: join(root, "projects"), grokRoot, isAlive: () => true });
    const at = Date.parse("2026-09-27T04:46:52Z");
    for (const sessionId of [GROK_PARENT_ID, GROK_CHILD_ID]) {
      const recorded = registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId, cwd: "/w" }, at,
        { markers: { claude: CLAUDE_ID }, ppid: 4900 });
      await registry.resolveLineage(recorded.key, lineage, at);
    }
    const scanner = new LocalAgentScanner({
      sessionsRoot: join(root, "codex"), database: join(root, "none.sqlite"), claudeRoot: join(root, "projects"),
      grokRoot, orcaAccounts: null, orcaStatus: join(root, "orca.json"), lineage: null
    });
    const raws = await scanner.annotateGrokSubagents(registry.merge([], at));
    const byId = new Map(raws.map((raw) => [raw.session, raw]));
    const child = byId.get(GROK_CHILD_ID);
    assert.equal(child.parent, GROK_PARENT_ID, "Grok's subagents/ record wins over the hook's lineage");
    assert.equal(child.parent_provider, "grok");
    assert.equal(child.headless, undefined, "a sub-agent is a worker, not a one-shot run");
    assert.equal(byId.get(GROK_PARENT_ID).parent, CLAUDE_ID, "the parent itself keeps its lineage parent");
    assert.equal(byId.get(GROK_PARENT_ID).headless, true);

    const projected = new Map(projectLocalSnapshot({ sessions: raws }).sessions.map((session) => [session.localSessionId, session]));
    assert.equal(projected.get(GROK_CHILD_ID).parentSessionId, `local:grok:${GROK_PARENT_ID}`);
    assert.equal(projected.get(GROK_CHILD_ID).parentProof, undefined);
    assert.equal(projected.get(GROK_CHILD_ID).openerInstanceId, CLAUDE_ID, "the chain still roots at the launcher");
    assert.equal(projected.get(GROK_PARENT_ID).parentSessionId, `local:claude:${CLAUDE_ID}`);
  });
});

test("the grok sub-agent resolver beats lineage in the scan and rereads a workspace only when it changes", async () => {
  const { GrokSubagentParents, grokSubagentLinks } = await import("../src/local-agents/grok.js");
  const { utimes } = await import("node:fs/promises");
  await withTempDirectory(async (root) => {
    const grokRoot = join(root, "grok");
    const workspace = await grokSubagentLayout(grokRoot, "/w", { meta: false });
    assert.deepEqual([...await grokSubagentLinks(workspace)], [[GROK_CHILD_ID, GROK_PARENT_ID]],
      "the directory layout names the parent without meta.json");

    // A process-scanned child: it shares its parent's pid and argv.
    const item = (session) => ({
      provider: "grok", session, link_session: session, pid: 4866, headless: true, parent: null,
      transcript: join(workspace, session)
    });
    const items = [item(GROK_PARENT_ID), item(GROK_CHILD_ID)];
    // Whole seconds, so restoring the mtime below restores it exactly.
    const mtime = 1_790_000_000;
    await utimes(workspace, mtime, mtime);
    const resolver = new GrokSubagentParents();
    await resolver.annotate(items);
    const resolveCalls = [];
    await annotateLineage(items, {
      refresh: async () => {},
      resolve: async (pid, self) => {
        resolveCalls.push(self.session);
        return { parent: { provider: "claude", session: CLAUDE_ID }, headless: true };
      }
    });
    assert.equal(items[1].parent, GROK_PARENT_ID);
    assert.equal(items[1].parent_source, "grok-subagent");
    assert.equal(items[1].headless, undefined);
    assert.deepEqual(resolveCalls, [GROK_PARENT_ID], "lineage is only the fallback");
    assert.equal(items[0].parent, CLAUDE_ID);

    // A second sub-agent recorded without the workspace mtime moving is not
    // looked for: the cached links stand.
    await mkdir(join(workspace, GROK_PARENT_ID, "subagents", "second-child"), { recursive: true });
    await utimes(workspace, mtime, mtime);
    const second = [item("second-child")];
    await resolver.annotate(second);
    assert.equal(second[0].parent, null, "an unchanged workspace is not rescanned");
    // Its session directory appearing is what moves the mtime.
    await mkdir(join(workspace, "second-child"));
    await utimes(workspace, mtime, mtime + 5);
    await resolver.annotate(second);
    assert.equal(second[0].parent, GROK_PARENT_ID);
  });
});

test("an old process table no longer answers liveness", async () => {
  const lineage = new ProcessLineage({ claudeSessionsDir: "/nonexistent", run: async () => "" });
  assert.equal(lineage.freshTable(1_000), null, "never loaded");
  await lineage.refresh(1_000);
  assert.equal(lineage.freshTable(1_004), lineage.table);
  assert.equal(lineage.freshTable(1_100), null, "a pid may have been reused since");
});
