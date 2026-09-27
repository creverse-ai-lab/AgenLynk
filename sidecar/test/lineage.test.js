import assert from "node:assert/strict";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { HookSessions } from "../src/hooks/registry.js";
import {
  annotateLineage,
  headlessArgs,
  hookLineageHeaders,
  lineageMarkers,
  markerParent,
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
  assert.equal(solo.role, "frontdoor", "unparented headless work is kept, not hidden");
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

test("a hook-only session with no activity and no transcript is held back, then dropped", async () => {
  await withTempDirectory(async (root) => {
    const claudeRoot = join(root, "projects");
    const registry = new HookSessions({ claudeRoot, grokRoot: join(root, "grok") });
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

    // A session with a transcript on disk (a resumed one) is listed at start.
    await mkdir(join(claudeRoot, "p"), { recursive: true });
    await writeFile(join(claudeRoot, "p", "resumed.jsonl"), "{}\n");
    const resumed = registry.record("claude", {
      ...probe, session_id: "resumed", transcript_path: join(claudeRoot, "p", "resumed.jsonl"), hook_event_name: "SessionStart"
    }, at);
    assert.equal(resumed.heldBack, false);
    assert.ok(registry.merge([], at).some((raw) => raw.session === "resumed"));

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
    const registry = new HookSessions({ claudeRoot: join(root, "projects"), grokRoot: join(root, "grok") });
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
