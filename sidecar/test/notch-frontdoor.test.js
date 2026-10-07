import assert from "node:assert/strict";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { chatFrontdoor } from "../src/app/notch-chat.js";
import { HookSessions } from "../src/hooks/registry.js";

const at = Date.parse("2026-10-05T09:00:00Z");

test("a notch chat names the Frontdoor it is opened for", () => {
  assert.deepEqual(chatFrontdoor({ frontdoor: "local:claude:9ee398ff-c0f7" }), {
    provider: "claude", sessionId: "9ee398ff-c0f7", monitorSessionId: "local:claude:9ee398ff-c0f7"
  });
  assert.throws(() => chatFrontdoor({}), /frontdoor must be/);
  assert.throws(() => chatFrontdoor({ frontdoor: "acp-123" }), /frontdoor must be/, "a Gateway Worker is not a Frontdoor");
  assert.throws(() => chatFrontdoor({ frontdoor: "local:gemini:x" }), /frontdoor must be/);
  assert.throws(() => chatFrontdoor({ frontdoor: "local:codex:has space" }), /frontdoor must be/);
});

test("a session keeps the folder it started in, not where its shell went", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere" });
  registry.record("grok", { hook_event_name: "SessionStart", sessionId: "g1", cwd: "/work/AgenLynk" }, at);
  registry.record("grok", { hook_event_name: "PreToolUse", sessionId: "g1", cwd: "/work/AgenLynk/sidecar/src/hooks" }, at + 1000);
  const [raw] = registry.merge([{ provider: "grok", session: "g1", state: "running", time: at / 1000, cwd: "/work/AgenLynk/sidecar/src/hooks" }], at + 1000);
  assert.equal(raw.cwd, "/work/AgenLynk", "seen from SessionStart, the hook knows the launch folder");
  const late = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere" });
  late.record("grok", { hook_event_name: "PreToolUse", sessionId: "g2", cwd: "/work/AgenLynk/deep" }, at);
  const [scanned] = late.merge([{ provider: "grok", session: "g2", state: "running", time: at / 1000, cwd: "/work/AgenLynk" }], at);
  assert.equal(scanned.cwd, "/work/AgenLynk", "joined mid-way, the hook does not override the scanner's folder");
});

test("a Claude turn ending with background tasks out is still running", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere" });
  registry.record("claude", { hook_event_name: "UserPromptSubmit", session_id: "c1", cwd: "/w" }, at);
  registry.record("claude", { hook_event_name: "Stop", session_id: "c1", background_tasks: [{ id: "t1" }] }, at + 1000);
  const [busy] = registry.merge([], at + 1000);
  assert.equal(busy.state, "running");
  const [stillBusy] = registry.merge([], at + 60_000);
  assert.equal(stillBusy.state, "running");
  const [left] = registry.merge([], at + 1000 + 121_000);
  assert.equal(left.state, "ready", "background work that never reports back leaves it at rest");
  registry.record("claude", { hook_event_name: "UserPromptSubmit", session_id: "c1" }, at + 200_000);
  registry.record("claude", { hook_event_name: "Stop", session_id: "c1", background_tasks: [] }, at + 201_000);
  const [rest] = registry.merge([], at + 201_000);
  assert.equal(rest.state, "ready");
});

test("a session whose process is gone drops out, without waiting for SessionEnd", () => {
  const alive = new Set([111]);
  const registry = new HookSessions({ claudeRoot: "/nowhere", isAlive: (pid) => alive.has(pid) });
  registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g1", cwd: "/w" }, at);
  registry.sessions.get("grok:g1").agentPid = 111;
  assert.equal(registry.merge([], at).length, 1);
  alive.delete(111);
  assert.deepEqual(registry.merge([{ provider: "grok", session: "g1", state: "ready", time: at / 1000 }], at + 1000), [],
    "the scanner's leftover record goes too");
  registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g1", cwd: "/w" }, at + 5000);
  assert.equal(registry.sessions.get("grok:g1").agentPid, undefined, "a resumed session starts over, not judged by the dead pid");
  assert.equal(registry.merge([], at + 5000).length, 1);
});

test("a replied Stop marks the session running again", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere" });
  registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g1", cwd: "/w" }, at - 1000);
  registry.record("grok", { hook_event_name: "Stop", hookEventName: "stop", sessionId: "g1", cwd: "/w" }, at);
  assert.equal(registry.merge([], at)[0].state, "ready");
  registry.markRunning("grok:g1", at + 500);
  const [raw] = registry.merge([], at + 500);
  assert.equal(raw.state, "running");
});

test("a desktop- or IDE-hosted Claude (sdk-cli, kind interactive) can be answered from the notch", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agenlynk-claude-sessions-"));
  try {
    await mkdir(dir, { recursive: true });
    await writeFile(join(dir, "4242.json"), JSON.stringify({ pid: 4242, sessionId: "c9", cwd: "/projects/app", kind: "interactive", entrypoint: "sdk-cli" }));
    const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: dir, isAlive: () => true });
    registry.record("claude", { hook_event_name: "Stop", session_id: "c9", cwd: "/projects/app/src" }, at, {
      markers: { entrypoint: "sdk-cli" }, ppid: 9000
    });
    const lineage = {
      table: new Map([[9000, {}]]),
      refresh: async () => {},
      agentPidFromHook: () => 4242,
      resolve: async () => ({ parent: null, headless: false })
    };
    await registry.resolveLineage("claude:c9", lineage, at);
    const target = registry.replyTarget("claude:c9");
    assert.equal(target.eligible, true);
    assert.equal(target.cwd, "/projects/app", "Claude's own record names the folder it started in");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("an idle Claude Frontdoor with no live process record has ended", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agenlynk-claude-live-"));
  try {
    await writeFile(join(dir, "1.json"), JSON.stringify({ pid: 1, sessionId: "alive", cwd: "/projects/app" }));
    await writeFile(join(dir, "2.json"), JSON.stringify({ pid: 2, sessionId: "crashed", cwd: "/projects/old" }));
    const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: dir, isAlive: (pid) => pid === 1 });
    const merged = registry.merge([
      { provider: "claude", session: "alive", state: "ready", time: at / 1000, cwd: "/projects/app/deep/dir" },
      { provider: "claude", session: "gone", state: "ready", time: at / 1000 },
      { provider: "claude", session: "gone-but-running", state: "running", time: at / 1000 },
      { provider: "claude", session: "subagent", state: "ready", time: at / 1000, parent: "alive" },
      { provider: "grok", session: "g", state: "ready", time: at / 1000 },
      { provider: "claude", session: "crashed", state: "ready", time: at / 1000 }
    ], at);
    assert.deepEqual(merged.map((raw) => raw.session).sort(), ["alive", "g", "gone-but-running", "subagent"]);
    assert.equal(merged.find((raw) => raw.session === "alive").cwd, "/projects/app", "named by the folder it started in");
    const unknown = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: join(dir, "missing"), isAlive: () => true });
    assert.equal(unknown.merge([{ provider: "claude", session: "gone", state: "ready", time: at / 1000 }], at).length, 1,
      "without Claude's records nothing is judged ended");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("a SessionStart (new launch or --resume) learns the process again", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere", isAlive: () => true });
  registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g1", cwd: "/w" }, at, { ppid: 100 });
  Object.assign(registry.sessions.get("grok:g1"), { agentPid: 111, agentStart: "Mon Oct 5 07:00:00 2026", lineageResolved: true });
  registry.record("grok", { hook_event_name: "SessionStart", sessionId: "g1", cwd: "/w" }, at + 1000, { ppid: 200 });
  const entry = registry.sessions.get("grok:g1");
  assert.equal(entry.agentPid, undefined);
  assert.equal(entry.lineageResolved, undefined);
  assert.equal(entry.ppid, 200, "the new process's hook parent is taken");
});

test("a Stop with background tasks out is never held for a reply", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere", isAlive: () => true });
  registry.record("claude", { hook_event_name: "Stop", session_id: "c1", background_tasks: [{ id: "t" }] }, at, { ppid: 9 });
  Object.assign(registry.sessions.get("claude:c1"), { agentPid: 10, lineageResolved: true });
  assert.equal(registry.replyTarget("claude:c1").eligible, false);
  registry.record("claude", { hook_event_name: "Stop", session_id: "c1", background_tasks: [] }, at + 1000);
  assert.equal(registry.replyTarget("claude:c1").eligible, true);
});

test("a headless host that asks a person for permission can be answered", () => {
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere", isAlive: () => true });
  registry.record("claude", { hook_event_name: "Stop", session_id: "c2" }, at, { ppid: 9 });
  Object.assign(registry.sessions.get("claude:c2"), { agentPid: 10, lineageResolved: true, headless: true });
  assert.equal(registry.replyTarget("claude:c2").eligible, false, "a one-shot run is not held");
  registry.sessions.get("claude:c2").interactive = true;
  assert.equal(registry.replyTarget("claude:c2").eligible, true, "a chat host (--permission-prompt-tool stdio) is a person");
});

test("a Stop is held only while its own process is alive (same pid and start)", () => {
  let alive = true;
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere", isAlive: () => alive });
  registry.record("grok", { hook_event_name: "Stop", sessionId: "g1", cwd: "/w" }, at, { ppid: 9 });
  Object.assign(registry.sessions.get("grok:g1"), { agentPid: 10, lineageResolved: true });
  assert.equal(registry.replyTarget("grok:g1").eligible, true);
  alive = false;
  assert.equal(registry.replyTarget("grok:g1").eligible, false);
});

test("an empty ~/.claude/sessions means no Claude is running; a reused pid is not the session", async () => {
  const dir = await mkdtemp(join(tmpdir(), "agenlynk-claude-empty-"));
  try {
    const empty = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: dir, isAlive: () => true });
    assert.deepEqual(empty.merge([{ provider: "claude", session: "gone", state: "ready", time: at / 1000 }], at), [],
      "the last Claude ended: its idle row goes");
    await writeFile(join(dir, "7.json"), JSON.stringify({ pid: 7, sessionId: "old", procStart: "Mon Oct  5 01:00:00 2026" }));
    const reused = new HookSessions({
      claudeRoot: "/nowhere", claudeSessionsDir: dir,
      isAlive: (pid, start) => pid === 7 && (start == null || start.replace(/\s+/g, " ") === "Mon Oct 5 09:00:00 2026")
    });
    assert.deepEqual(reused.merge([{ provider: "claude", session: "old", state: "ready", time: at / 1000 }], at), [],
      "pid 7 now belongs to a process started later");
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// The 1 s merge checked every live pid with a blocking `ps`; the lineage
// table already holds start times.
test("liveness reads start times from the process table when it has them", async () => {
  const { processAliveFrom } = await import("../src/hooks/registry.js");
  const table = new Map([[process.pid, { start: "Mon Oct  6 09:00:00 2026" }]]);
  const alive = processAliveFrom(() => table);
  assert.equal(alive(process.pid, "Mon Oct 6 09:00:00 2026"), true, "the same start, spacing aside");
  assert.equal(alive(process.pid, "Tue Oct 7 10:00:00 2026"), false, "a reused pid is not the session");
  assert.equal(alive(999_999_999, "Mon Oct 6 09:00:00 2026"), false, "a gone pid");
});
