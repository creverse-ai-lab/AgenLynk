import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { writeHookEndpoint } from "../src/hooks/endpoint.js";
import { ensureHooks, hookStatus, installHooks, uninstallHooks } from "../src/hooks/installer.js";
import { HookSessions } from "../src/hooks/registry.js";
import { HookNormalizer, readHookPayload } from "../src/normalize/hook.js";
import { codexApprovesAutomatically } from "../src/local-agents/codex.js";

const hookScript = fileURLToPath(new URL("../hooks/agenlynk-hook.sh", import.meta.url));

async function withTempDirectory(run) {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-hooks-"));
  try {
    return await run(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
}

// Another tool's hooks, formatted the way installers write them, so the
// round trip can be checked byte for byte.
const foreignGroup = { hooks: [{ type: "command", command: "/bin/sh '/Users/test/.orca/agent-hooks/claude-hook.sh'", timeout: 10 }] };
const pretty = (value) => `${JSON.stringify(value, null, 2)}\n`;

async function fakeHomes(root) {
  const env = {
    CLAUDE_CONFIG_DIR: join(root, "claude"),
    CODEX_HOME: join(root, "codex"),
    GROK_HOME: join(root, "grok"),
    AGENLYNK_HOME: join(root, "agenlynk")
  };
  for (const home of [env.CLAUDE_CONFIG_DIR, env.CODEX_HOME, env.GROK_HOME]) await mkdir(home, { recursive: true });
  const claudeSettings = pretty({ model: "opus", hooks: { PreToolUse: [{ matcher: "*", ...foreignGroup }], Stop: [foreignGroup] } });
  const codexHooks = pretty({ hooks: { PreToolUse: [foreignGroup] } });
  await writeFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), claudeSettings);
  await writeFile(join(env.CODEX_HOME, "hooks.json"), codexHooks);
  return { env, claudeSettings, codexHooks };
}

test("installing hooks appends ours, keeps other tools' hooks, and round-trips on uninstall", async () => {
  await withTempDirectory(async (root) => {
    const { env, claudeSettings, codexHooks } = await fakeHomes(root);
    assert.equal(hookStatus({ env }).consentRequired, true);
    assert.deepEqual(ensureHooks({ env }), { skipped: "consent_required" }, "nothing is written before the user agrees");
    assert.equal(await readFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "utf8"), claudeSettings);
    const installed = installHooks({ env, consent: true });
    assert.deepEqual(installed.errors, {});
    assert.deepEqual(installed.changes.map((change) => change.provider).sort(), ["claude", "codex", "grok"]);
    assert.ok(Object.values(installed.targets).every((target) => target.installed));

    const claude = JSON.parse(await readFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "utf8"));
    assert.equal(claude.model, "opus", "unrelated settings are kept");
    assert.deepEqual(claude.hooks.PreToolUse[0], { matcher: "*", ...foreignGroup }, "the other tool's group stays first");
    assert.match(claude.hooks.PreToolUse[1].hooks[0].command, /agenlynk-hook\.sh' claude/);
    assert.equal(claude.hooks.PreToolUse[1].matcher, "*");
    assert.equal(claude.hooks.Stop[1].matcher, undefined);
    const grok = JSON.parse(await readFile(join(env.GROK_HOME, "hooks", "agenlynk.json"), "utf8"));
    assert.match(grok.hooks.Notification[0].hooks[0].command, /agenlynk-hook\.sh' grok/);
    assert.ok(existsSync(installed.script), "the script is installed");
    assert.match(installed.script, /hooks\/[0-9a-f]{12}\/agenlynk-hook\.sh$/, "under a directory named for its content");
    assert.equal(hookStatus({ env }).consentRequired, false);
    assert.equal((await readdir(join(env.AGENLYNK_HOME, "backups"))).length, 2, "each existing file is backed up");

    assert.deepEqual(installHooks({ env }).changes, [], "a second install is a no-op");
    assert.deepEqual(ensureHooks({ env }), { skipped: "current" });

    const removed = uninstallHooks({ env });
    assert.deepEqual(removed.errors, {});
    assert.equal(await readFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "utf8"), claudeSettings);
    assert.equal(await readFile(join(env.CODEX_HOME, "hooks.json"), "utf8"), codexHooks);
    assert.equal(existsSync(join(env.GROK_HOME, "hooks", "agenlynk.json")), false, "our own file is removed");
    assert.deepEqual(ensureHooks({ env }), { skipped: "disabled" }, "turning hooks off is remembered across starts");
  });
});

test("Codex hooks report pending trust until Codex records it", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    installHooks({ env, only: ["codex"], consent: true });
    const pending = hookStatus({ env, only: ["codex"] }).targets.codex;
    assert.equal(pending.needsTrust, true);
    assert.ok(pending.untrustedEvents.includes("PermissionRequest"));

    // What Codex writes after /hooks approval: position-keyed trust entries.
    const hooksFile = join(env.CODEX_HOME, "hooks.json");
    const hooks = JSON.parse(await readFile(hooksFile, "utf8")).hooks;
    const lines = Object.entries(hooks).map(([event, groups]) => {
      const index = groups.findIndex((group) => group.hooks[0].command.includes("agenlynk-hook.sh"));
      const snake = event.replace(/([a-z])([A-Z])/g, "$1_$2").toLowerCase();
      return `[hooks.state."${hooksFile}:${snake}:${index}:0"]\ntrusted_hash = "x"\n`;
    });
    await writeFile(join(env.CODEX_HOME, "config.toml"), lines.join("\n"));
    assert.equal(hookStatus({ env, only: ["codex"] }).targets.codex.needsTrust, false);
    // Codex prints every hook run, so AgenLynk stays off PreToolUse there; the
    // other tool's group at :0:0 is untouched.
    assert.deepEqual(hooks.PreToolUse, [foreignGroup]);

    // A changed command (a new script version) invalidates that approval:
    // the trusted_hash Codex recorded belongs to the old definition.
    const edited = JSON.parse(await readFile(hooksFile, "utf8"));
    edited.hooks.Stop.find((group) => group.hooks[0].command.includes("agenlynk-hook.sh")).hooks[0].command = "/bin/sh /old/0123456789ab/agenlynk-hook.sh codex";
    await writeFile(hooksFile, JSON.stringify(edited, null, 2));
    installHooks({ env, only: ["codex"] });
    const stale = hookStatus({ env, only: ["codex"] }).targets.codex;
    assert.equal(stale.needsTrust, true, "an approval of the old definition does not count");
    assert.ok(stale.untrustedEvents.includes("Stop"));
    // Re-approval in Codex writes a new hash.
    await writeFile(join(env.CODEX_HOME, "config.toml"), (await readFile(join(env.CODEX_HOME, "config.toml"), "utf8")).replaceAll('trusted_hash = "x"', 'trusted_hash = "y"'));
    assert.equal(hookStatus({ env, only: ["codex"] }).targets.codex.needsTrust, false);
  });
});

test("a malformed config file is left untouched and a per-CLI opt-out survives restarts", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    await writeFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "{ not json");
    const result = installHooks({ env, consent: true });
    assert.match(result.errors.claude, /invalid JSON/);
    assert.equal(await readFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "utf8"), "{ not json");

    await writeFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "{}\n");
    installHooks({ env });
    uninstallHooks({ env, only: ["grok"] });
    ensureHooks({ env });
    const status = hookStatus({ env });
    assert.equal(status.targets.grok.installed, false, "the opted-out CLI is not reinstalled on start");
    assert.equal(status.targets.grok.disabled, true);
    assert.equal(status.targets.claude.installed, true);
  });
});

test("hook payloads from all three CLIs read the same", () => {
  const claude = readHookPayload("claude", { hook_event_name: "PreToolUse", session_id: "c", tool_name: "Bash", tool_use_id: "toolu_1", cwd: "/w" });
  const codex = readHookPayload("codex", { hook_event_name: "PermissionRequest", session_id: "x", model: "gpt-5.6", turn_id: "t" });
  const grok = readHookPayload("grok", { hookEventName: "pre_tool_use", hook_event_name: "PreToolUse", sessionId: "g", toolName: "read_file", toolUseId: "u1" });
  assert.deepEqual([claude.event, claude.sessionId, claude.toolUseId], ["PreToolUse", "c", "toolu_1"]);
  assert.deepEqual([codex.event, codex.model, codex.turnId], ["PermissionRequest", "gpt-5.6", "t"]);
  assert.deepEqual([grok.event, grok.sessionId, grok.toolName], ["PreToolUse", "g", "read_file"]);
  assert.equal(readHookPayload("grok", { hookEventName: "session_start", sessionId: "g" }).event, "SessionStart");
});

test("a permission prompt is pending until the next sign of progress, for every CLI", () => {
  const prompts = {
    claude: [{ hook_event_name: "PermissionRequest", session_id: "s", tool_name: "Bash", tool_input: { command: "rm x" } }, { hook_event_name: "PostToolUse", session_id: "s", tool_use_id: "toolu_9" }],
    codex: [{ hook_event_name: "PermissionRequest", session_id: "s", tool_name: "exec" }, { hook_event_name: "PostToolUse", session_id: "s" }],
    grok: [{ hook_event_name: "Notification", sessionId: "s", notificationType: "permission_prompt", message: "Allow write?" }, { hook_event_name: "PostToolUse", sessionId: "s" }]
  };
  for (const [provider, [ask, progress]] of Object.entries(prompts)) {
    const normalizer = new HookNormalizer();
    const asked = normalizer.ingest(provider, ask, Date.parse("2026-09-26T00:00:00Z"));
    assert.equal(asked.status, "waiting_permission", provider);
    const [request] = asked.events;
    assert.equal(request.kind, "permission_request");
    assert.equal(request.status, "pending");
    const answered = normalizer.ingest(provider, progress, Date.parse("2026-09-26T00:00:05Z"));
    assert.equal(answered.status, "running", provider);
    const resolved = answered.events.find((event) => event.key === request.key);
    assert.equal(resolved?.status, "completed", `${provider} resolves its prompt`);
    assert.equal(resolved.detail.outcome, "approved");
  }
});

test("a permission request nobody is asked about is not a wait", () => {
  const ask = { hook_event_name: "PermissionRequest", session_id: "s", tool_name: "exec" };
  assert.equal(new HookNormalizer().ingest("codex", ask).status, "waiting_permission");
  const bypass = new HookNormalizer().ingest("codex", { ...ask, permission_mode: "bypassPermissions" });
  assert.deepEqual([bypass.status, bypass.events], ["running", []]);
  const reviewed = new HookNormalizer().ingest("codex", { ...ask, permission_mode: "default" }, Date.now(), { automaticApproval: true });
  assert.deepEqual([reviewed.status, reviewed.events], ["running", []]);
  assert.equal(new HookNormalizer().ingest("claude", { ...ask, permission_mode: "dontAsk" }).status, "running");
  assert.equal(new HookNormalizer().ingest("claude", { ...ask, permission_mode: "default" }).status, "waiting_permission");
});

test("Codex's approval mode is read from the turn's turn_context", async () => {
  const directory = await mkdtemp(join(tmpdir(), "agenlynk-codex-approval-"));
  try {
    const rollout = (reviewer, policy = "on-request") => [
      { type: "session_meta", payload: { id: "t" } },
      { type: "turn_context", payload: { turn_id: "turn-1", approval_policy: policy, approvals_reviewer: reviewer } },
      { type: "response_item", payload: { type: "message" } }
    ].map((record) => JSON.stringify(record)).join("\n") + "\n";
    const auto = join(directory, "auto.jsonl");
    const user = join(directory, "user.jsonl");
    const never = join(directory, "never.jsonl");
    await writeFile(auto, rollout("auto_review"));
    await writeFile(user, rollout("user"));
    await writeFile(never, rollout("user", "never"));
    assert.equal(await codexApprovesAutomatically(auto, "turn-1"), true, "Auto review decides without the user");
    assert.equal(await codexApprovesAutomatically(user, "turn-1"), false);
    assert.equal(await codexApprovesAutomatically(never, "turn-1"), true);
    assert.equal(await codexApprovesAutomatically(join(directory, "missing.jsonl"), "turn-1"), false, "unknown asks, as before");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("a question is a wait for input, in any permission mode", () => {
  const normalizer = new HookNormalizer();
  const ask = { hook_event_name: "PermissionRequest", session_id: "s", tool_name: "AskUserQuestion", permission_mode: "bypassPermissions" };
  const asked = normalizer.ingest("claude", ask);
  assert.equal(asked.status, "waiting_input");
  assert.equal(normalizer.ingest("claude", { hook_event_name: "Notification", session_id: "s", notification_type: "permission_prompt" }).status,
    "waiting_input", "the dialog's own notice keeps it a question");
  const answered = normalizer.ingest("claude", { hook_event_name: "PostToolUse", session_id: "s", tool_name: "AskUserQuestion" });
  assert.equal(answered.status, "running");
  assert.equal(answered.events[0].detail.outcome, "approved");
});

test("another agent's tool does not answer a sub-agent's prompt", () => {
  const normalizer = new HookNormalizer();
  normalizer.ingest("claude", { hook_event_name: "PermissionRequest", session_id: "s", agent_id: "a1", tool_name: "Bash" });
  const other = normalizer.ingest("claude", { hook_event_name: "PostToolUse", session_id: "s", agent_id: "a2", tool_name: "Read", tool_use_id: "t2" });
  assert.equal(other.status, "waiting_permission", "a parallel sub-agent's tool leaves the prompt open");
  assert.deepEqual(other.events, []);
  assert.equal(normalizer.ingest("claude", { hook_event_name: "SubagentStart", session_id: "s" }).status, "waiting_permission");
  const own = normalizer.ingest("claude", { hook_event_name: "PostToolUse", session_id: "s", agent_id: "a1", tool_name: "Bash", tool_use_id: "t1" });
  assert.equal(own.status, "running");
  assert.equal(own.events[0].detail.outcome, "approved");

  const ending = new HookNormalizer();
  ending.ingest("claude", { hook_event_name: "PermissionRequest", session_id: "s", tool_name: "Bash" });
  assert.equal(ending.ingest("claude", { hook_event_name: "Stop", session_id: "s", agent_id: "a2" }).status, "waiting_permission",
    "a sub-agent ending does not end the main line's prompt");

  const subagentEnds = new HookNormalizer();
  subagentEnds.ingest("claude", { hook_event_name: "PermissionRequest", session_id: "s", agent_id: "a1", tool_name: "Bash" });
  const stopped = subagentEnds.ingest("claude", { hook_event_name: "SubagentStop", session_id: "s", agent_id: "a1" });
  assert.equal(stopped.status, "running", "the sub-agent's own end closes its prompt");
  assert.equal(stopped.events[0]?.detail.outcome, "cancelled");
  const otherTask = new HookNormalizer();
  otherTask.ingest("claude", { hook_event_name: "PermissionRequest", session_id: "s", agent_id: "a1", tool_name: "Bash" });
  assert.equal(otherTask.ingest("claude", { hook_event_name: "PostToolUse", session_id: "s", tool_name: "Task", tool_use_id: "task2" }).status,
    "waiting_permission", "a Task result does not say which sub-agent finished");

  const grok = new HookNormalizer();
  grok.ingest("grok", { hook_event_name: "Notification", sessionId: "g", notificationType: "permission_prompt" });
  const ended = grok.ingest("grok", { hook_event_name: "SubagentStop", sessionId: "g" });
  assert.deepEqual([ended.status, ended.events[0]?.detail.outcome], ["idle", "cancelled"], "a Grok sub-agent session's turn end");
});

test("a turn that ends on an error is failed, not done", () => {
  assert.equal(new HookNormalizer().ingest("claude", { hook_event_name: "StopFailure", session_id: "s" }).status, "failed");
  assert.equal(new HookNormalizer().ingest("claude", { hook_event_name: "StopFailure", session_id: "s", agent_id: "a1" }).status,
    "running", "a sub-agent failing leaves its parent working");
  const registry = new HookSessions({ claudeRoot: "/nowhere", claudeSessionsDir: "/nowhere", isAlive: () => true });
  registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g", cwd: "/w" }, 1_000);
  registry.record("grok", { hook_event_name: "StopFailure", sessionId: "g", cwd: "/w" }, 2_000);
  assert.equal(registry.merge([], 2_000)[0].state, "failed");
});

test("a denied prompt reads as denied and an abandoned one as cancelled", () => {
  const ask = { hook_event_name: "PermissionRequest", session_id: "s", tool_name: "Bash" };
  const denied = new HookNormalizer();
  denied.ingest("claude", ask);
  const [refusal] = denied.ingest("claude", { hook_event_name: "PermissionDenied", session_id: "s" }).events;
  assert.deepEqual([refusal.status, refusal.detail.outcome], ["failed", "denied"]);

  const abandoned = new HookNormalizer();
  abandoned.ingest("claude", ask);
  const [ended] = abandoned.ingest("claude", { hook_event_name: "Stop", session_id: "s" }).events;
  assert.deepEqual([ended.status, ended.detail.outcome], ["cancelled", "cancelled"]);

  const quiet = new HookNormalizer();
  quiet.ingest("grok", { hook_event_name: "Notification", sessionId: "s", notificationType: "permission_prompt" });
  assert.deepEqual(quiet.ingest("grok", { hook_event_name: "SubagentStart", sessionId: "s" }).events, [],
    "an unrelated event says nothing about the prompt");
});

test("only Claude hooks create tool events, keyed like the transcript", () => {
  const claude = new HookNormalizer().ingest("claude", { hook_event_name: "PreToolUse", session_id: "s", tool_use_id: "toolu_1", tool_name: "Bash", tool_input: { command: "ls" } });
  assert.deepEqual(claude.events.map((event) => [event.key, event.status]), [["tool:toolu_1", "running"]]);
  const grok = new HookNormalizer().ingest("grok", { hook_event_name: "PreToolUse", sessionId: "s", toolUseId: "u1", toolName: "read_file" });
  assert.deepEqual(grok.events, [], "Grok's tool calls come from its transcript");
  const subagent = new HookNormalizer().ingest("claude", { hook_event_name: "Stop", session_id: "s", agent_id: "a1" });
  assert.equal(subagent.status, "running", "a subagent finishing does not end the parent's turn");
});

test("hook sessions overlay newer status, add unseen sessions, and drop ended ones", async () => {
  await withTempDirectory(async (root) => {
    const claudeRoot = join(root, "projects");
    const registry = new HookSessions({ claudeRoot, grokRoot: join(root, "grok") });
    const at = Date.parse("2026-09-26T00:00:10Z");
    registry.record("claude", { hook_event_name: "PermissionRequest", session_id: "c1", cwd: "/w", transcript_path: join(claudeRoot, "p", "c1.jsonl"), tool_name: "Bash" }, at);
    registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "g1", cwd: "/work" }, at);
    registry.record("claude", { hook_event_name: "PreToolUse", session_id: "evil", transcript_path: "/etc/passwd" }, at);
    assert.equal(registry.record("claude", { hookEventName: "stop", hook_event_name: "Stop", sessionId: "g1" }, at), null,
      "a Grok payload that came through Claude's hooks is not a Claude session");

    const merged = registry.merge([
      { provider: "claude", session: "c1", state: "running", time: at / 1000 - 5, cwd: "/w" }
    ], at);
    const byId = new Map(merged.map((raw) => [raw.session, raw]));
    assert.equal(byId.get("c1").state, "needs_permission", "the newer hook status wins");
    assert.equal(byId.get("c1").hooked, true);
    assert.equal(byId.get("g1").state, "running", "a session only a hook has seen is listed");
    assert.equal(byId.get("g1").transcript, join(root, "grok", encodeURIComponent("/work"), "g1"));
    assert.equal(byId.get("evil").transcript, null, "a payload cannot point the monitor at an arbitrary file");

    registry.record("grok", { hook_event_name: "SessionEnd", sessionId: "g1" }, at + 1000);
    const afterEnd = registry.merge([{ provider: "grok", session: "g1", state: "ready", time: 1 }], at + 1000);
    assert.equal(afterEnd.some((raw) => raw.session === "g1"), false, "SessionEnd removes the session even if the scanner still sees it");
    assert.ok(afterEnd.some((raw) => raw.session === "c1"), "other hook sessions stay");
  });
});

async function runHook(args, { env, stdin }) {
  return new Promise((resolve, reject) => {
    const child = spawn("/bin/sh", [hookScript, ...args], { env: { PATH: process.env.PATH, HOME: env.HOME, ...env } });
    let stdout = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.on("error", reject);
    child.on("exit", (code) => resolve({ code, stdout }));
    child.stdin.end(stdin);
  });
}

test("the hook script forwards to the sidecar, stays silent, and never blocks the agent", async () => {
  await withTempDirectory(async (root) => {
    const received = [];
    const lineageHeaders = [];
    const server = createServer((request, response) => {
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        received.push({ url: request.url, token: request.headers["x-agenlynk-hook-token"], body });
        lineageHeaders.push(Object.fromEntries(Object.entries(request.headers)
          .filter(([name]) => name.startsWith("x-agenlynk-") && name !== "x-agenlynk-hook-token")));
        response.writeHead(204).end();
      });
    });
    await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
    try {
      const endpoint = join(root, "hook-endpoint");
      writeHookEndpoint(endpoint, { port: server.address().port, token: "tok_123" });
      const env = { HOME: root, AGENLYNK_HOOK_ENDPOINT: endpoint };
      const payload = JSON.stringify({ hook_event_name: "Stop", session_id: "s" });

      const sent = await runHook(["claude"], { env, stdin: payload });
      assert.deepEqual(sent, { code: 0, stdout: "" }, "no output: the agent must never read a decision from it");
      assert.deepEqual(received, [{ url: "/api/hooks/claude", token: "tok_123", body: payload }]);

      assert.deepEqual(Object.keys(lineageHeaders[0]), ["x-agenlynk-hook-ppid"], "no markers without a launcher");

      await runHook(["claude"], { env: { ...env, GROK_SESSION_ID: "g", GROK_HOOK_EVENT: "stop" }, stdin: payload });
      assert.equal(received.length, 1, "the Claude registration stays quiet when Grok runs it");
      await runHook(["grok"], { env: { ...env, GROK_SESSION_ID: "g", GROK_HOOK_EVENT: "stop" }, stdin: payload });
      assert.equal(received.at(-1).url, "/api/hooks/grok");
      assert.equal(lineageHeaders.at(-1)["x-agenlynk-parent-grok"], undefined, "Grok's own id is not a launcher");

      // A Codex run from a Claude Code Bash tool inside a Grok shell.
      await runHook(["codex"], {
        env: {
          ...env,
          GROK_SESSION_ID: "grok-1",
          CLAUDE_CODE_SESSION_ID: "625cbd07-50b1-4ffa-b0bd-368891bb5085",
          CLAUDE_CODE_ENTRYPOINT: "cli",
          CODEX_THREAD_ID: "own-thread",
          ANTHROPIC_API_KEY: "sk-secret",
          CLAUDE_PID: "16964"
        },
        stdin: payload
      });
      assert.equal(received.at(-1).url, "/api/hooks/codex", "a CLI merely running inside Grok still reports");
      const forwarded = lineageHeaders.at(-1);
      assert.equal(forwarded["x-agenlynk-parent-claude"], "625cbd07-50b1-4ffa-b0bd-368891bb5085");
      assert.equal(forwarded["x-agenlynk-parent-grok"], "grok-1");
      assert.equal(forwarded["x-agenlynk-entrypoint"], "cli");
      assert.equal(forwarded["x-agenlynk-parent-codex"], undefined, "Codex's own thread is not a launcher");
      assert.match(forwarded["x-agenlynk-hook-ppid"], /^\d+$/);
      assert.deepEqual(Object.keys(forwarded).sort(), [
        "x-agenlynk-entrypoint", "x-agenlynk-hook-ppid", "x-agenlynk-parent-claude", "x-agenlynk-parent-grok"
      ], "no other environment is forwarded");
      assert.ok(!JSON.stringify(received.at(-1)).includes("sk-secret"));

      const before = received.length;
      await runHook(["grok"], {
        env: { ...env, CLAUDE_CODE_SESSION_ID: "x\r\nX-Injected: 1", CLAUDE_CODE_ENTRYPOINT: `a${"b".repeat(200)}` },
        stdin: payload
      });
      assert.equal(received.length, before + 1);
      assert.deepEqual(Object.keys(lineageHeaders.at(-1)), ["x-agenlynk-hook-ppid"], "malformed or oversized markers are dropped");

      await writeFile(endpoint, "AGENLYNK_HOOK_PORT=1; rm -rf /\nAGENLYNK_HOOK_TOKEN=x\n");
      assert.equal((await runHook(["codex"], { env, stdin: payload })).code, 0, "a tampered endpoint file is ignored");
      assert.equal(received.length, before + 1);
    } finally {
      await new Promise((resolve) => server.close(resolve));
    }

    const started = Date.now();
    const offline = await runHook(["codex"], { env: { HOME: root, AGENLYNK_HOOK_ENDPOINT: join(root, "hook-endpoint") }, stdin: "{}" });
    assert.equal(offline.code, 0, "AgenLynk not running is not an error");
    assert.ok(Date.now() - started < 3_000, "and costs the agent about a second at most");
  });
});

test("a live sidecar installs hooks on start and turns a hook into status within a tick", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    const monitorPath = fileURLToPath(new URL("../src/server/monitor.js", import.meta.url));
    const publicClient = fileURLToPath(new URL("./fixtures/monitor-orchestration/gateway-client/index.js", import.meta.url));
    const child = spawn(process.execPath, ["--disable-warning=ExperimentalWarning", monitorPath], {
      env: {
        ...process.env,
        ...env,
        ACP_GATEWAY_CLIENT_ENTRYPOINT: publicClient,
        ACP_GATEWAY_TEST_CONTROL_FILE: join(root, "control.json"),
        ACP_GATEWAY_CONTROL_TOKEN: "hooks-control-token-1234567890",
        ACP_GATEWAY_ROOT_ID: "hooks-root",
        ACP_GATEWAY_INSTALL_STATE: join(root, "install.json"),
        ACP_GATEWAY_MONITOR_PORT: "0",
        ACP_GATEWAY_MONITOR_AUTOSTART: "0",
        ACP_GATEWAY_MONITOR_DB: join(root, "monitor.db"),
        ACP_GATEWAY_MONITOR_HOOKS: "1",
        ACP_MONITOR_LOCAL_SCANNER: "0",
        ACP_GATEWAY_ACTIVE_ROOT: root
      },
      stdio: ["ignore", "pipe", "pipe"]
    });
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    try {
      const ready = await new Promise((resolve, reject) => {
        let buffered = "";
        child.stdout.on("data", (chunk) => {
          buffered += chunk;
          const line = buffered.split("\n").find((item) => item.includes("monitor_ready"));
          if (line) resolve(JSON.parse(line));
        });
        child.once("exit", () => reject(new Error(`sidecar exited: ${stderr}`)));
      });
      const headers = { authorization: `Bearer ${ready.apiToken}` };
      const before = await (await fetch(`${ready.url}/api/hooks`, { headers })).json();
      assert.equal(before.receiving, true);
      assert.equal(before.consentRequired, true, "the app has to ask first");
      assert.ok(Object.values(before.targets).every((target) => !target.installed), "start alone installs nothing");
      const status = await (await fetch(`${ready.url}/api/hooks`, {
        method: "POST",
        headers: { ...headers, "content-type": "application/json" },
        body: JSON.stringify({ action: "install", consent: true })
      })).json();
      assert.ok(Object.values(status.targets).every((target) => target.installed), "consent installs hooks for every CLI present");

      const script = status.script;
      const hookEnv = { HOME: root, AGENLYNK_HOME: env.AGENLYNK_HOME, AGENLYNK_HOOK_ENDPOINT: join(env.AGENLYNK_HOME, "hook-endpoint") };
      await runHookScript(script, "grok", hookEnv, { hook_event_name: "Notification", sessionId: "g-live", cwd: "/work", notificationType: "permission_prompt", message: "Allow write?" });

      let snapshot = null;
      for (let attempt = 0; attempt < 80; attempt += 1) {
        snapshot = await (await fetch(`${ready.url}/api/snapshot`, { headers })).json();
        if (snapshot.sessions.some((session) => session.sessionId === "local:grok:g-live")) break;
        await new Promise((resolve) => setTimeout(resolve, 25));
      }
      const session = snapshot.sessions.find((item) => item.sessionId === "local:grok:g-live");
      assert.equal(session?.status, "waiting_permission", "a Grok permission prompt shows up as waiting");
      assert.ok(session.capabilities.includes("live"));
      assert.equal(snapshot.events["local:grok:g-live"][0].kind, "permission_request");

      const unauthorized = await fetch(`${ready.url}/api/hooks/grok`, { method: "POST", body: "{}" });
      assert.equal(unauthorized.status, 401, "hooks need the endpoint file's token");
    } finally {
      if (child.exitCode == null) {
        child.kill("SIGTERM");
        await new Promise((resolve) => child.once("exit", resolve));
      }
    }
    assert.equal(existsSync(join(env.AGENLYNK_HOME, "hook-endpoint")), false, "shutdown removes its endpoint");
  });
});

function runHookScript(script, provider, env, payload) {
  return new Promise((resolve, reject) => {
    const child = spawn("/bin/sh", [script, provider], { env: { PATH: process.env.PATH, ...env } });
    child.on("error", reject);
    child.on("exit", resolve);
    child.stdin.end(JSON.stringify(payload));
  });
}

test("a hook event this version no longer registers is removed on update", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    const old = { hooks: [{ type: "command", command: "/bin/sh '/x/hooks/agenlynk-hook.sh' codex", timeout: 5 }] };
    await writeFile(join(env.CODEX_HOME, "hooks.json"), pretty({ hooks: { PreToolUse: [foreignGroup, old], SubagentStart: [old] } }));
    installHooks({ env, only: ["codex"], consent: true });
    const hooks = JSON.parse(await readFile(join(env.CODEX_HOME, "hooks.json"), "utf8")).hooks;
    assert.deepEqual(hooks.PreToolUse, [foreignGroup], "ours goes, the other tool's stays");
    assert.equal(hooks.SubagentStart, undefined);
    assert.ok(hooks.Stop.some((group) => group.hooks[0].command.includes("agenlynk-hook.sh")));
  });
});

test("updating one CLI keeps the script version another CLI still uses", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    installHooks({ env, consent: true });
    const scriptsRoot = join(env.AGENLYNK_HOME, "hooks");
    // Codex still names an older version (e.g. its update was skipped).
    const oldDir = join(scriptsRoot, "0123456789ab");
    await mkdir(oldDir, { recursive: true });
    await writeFile(join(oldDir, "agenlynk-hook.sh"), "#!/bin/sh\n");
    const hooksFile = join(env.CODEX_HOME, "hooks.json");
    const text = (await readFile(hooksFile, "utf8")).replace(/hooks\/[0-9a-f]{12}\/agenlynk-hook\.sh/g, "hooks/0123456789ab/agenlynk-hook.sh");
    await writeFile(hooksFile, text);
    installHooks({ env, only: ["claude"] });
    assert.ok(existsSync(join(oldDir, "agenlynk-hook.sh")), "a version a config still references is kept");
    installHooks({ env, only: ["codex"] });
    assert.equal(existsSync(oldDir), false, "once nothing references it, it goes");
  });
});

test("install and uninstall report every CLI, not only the ones acted on", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    const installed = installHooks({ env, only: ["codex"], consent: true });
    assert.deepEqual(Object.keys(installed.targets).sort(), ["claude", "codex", "grok"]);
    assert.equal(installed.targets.codex.installed, true);
    assert.equal(installed.targets.claude.installed, false);
    const removed = uninstallHooks({ env, only: ["codex"] });
    assert.deepEqual(Object.keys(removed.targets).sort(), ["claude", "codex", "grok"]);
  });
});

test("declining everything, then turning one CLI on, never installs the others on start", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    const declined = uninstallHooks({ env, decline: true });
    assert.ok(Object.values(declined.targets).every((target) => target.disabled), "a full decline turns every CLI off");
    assert.equal(declined.consentRequired, false);

    installHooks({ env, only: ["codex"], consent: true });
    ensureHooks({ env });
    const status = hookStatus({ env });
    assert.equal(status.targets.codex.installed, true);
    assert.equal(status.targets.codex.consented, true);
    assert.equal(status.targets.claude.installed, false, "Claude was not agreed to");
    assert.equal(status.targets.grok.installed, false, "Grok was not agreed to");
    assert.equal(status.targets.claude.disabled, true);
  });
});

test("start installs only the CLIs the user consented to, and not one installed later", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    await rm(env.GROK_HOME, { recursive: true, force: true });
    installHooks({ env, consent: true });
    assert.equal(hookStatus({ env }).targets.grok.consented, false, "an absent CLI is not agreed to by a full consent");

    // Grok is installed afterwards: start must not register it silently.
    await mkdir(env.GROK_HOME, { recursive: true });
    ensureHooks({ env });
    const status = hookStatus({ env });
    assert.equal(status.targets.grok.installed, false);
    assert.equal(status.targets.grok.disabled, false, "it reads as never turned on, not as turned off");
    assert.equal(status.targets.claude.installed, true);

    // A per-CLI consent from settings adds only that CLI.
    installHooks({ env, only: ["grok"], consent: true });
    assert.equal(hookStatus({ env }).targets.grok.installed, true);
  });
});

test("a hook state from before per-CLI consent keeps every CLI that was not turned off", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    await mkdir(env.AGENLYNK_HOME, { recursive: true });
    await writeFile(join(env.AGENLYNK_HOME, "hooks-state.json"), JSON.stringify({
      version: 1, enabled: true, consent: { version: 1 }, disabledProviders: ["grok"]
    }));
    ensureHooks({ env });
    const status = hookStatus({ env });
    assert.equal(status.targets.claude.installed, true);
    assert.equal(status.targets.codex.installed, true);
    assert.equal(status.targets.grok.installed, false);
  });
});

test("only the newest few backups of each config file are kept", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    let now = Date.parse("2026-08-07T00:00:00.000Z");
    for (let round = 0; round < 8; round += 1) {
      installHooks({ env, consent: true, now: now += 1_000 });
      uninstallHooks({ env, now: now += 1_000 });
    }
    const backups = await readdir(join(env.AGENLYNK_HOME, "backups"));
    const perFile = new Map();
    for (const name of backups) {
      const file = name.replace(/\.[^.]+\.bak$/, "");
      perFile.set(file, (perFile.get(file) ?? 0) + 1);
    }
    assert.ok(perFile.size >= 2, "both existing files were backed up");
    for (const [file, count] of perFile) assert.equal(count, 5, `${file} keeps five backups`);
  });
});

test("a grok sub-agent's SubagentStop is its own turn end, and a Claude subagent's is not", () => {
  const child = new HookNormalizer().ingest("grok", {
    hook_event_name: "SubagentStop", hookEventName: "subagent_stop", sessionId: "child", subagentType: "general-purpose", agentId: "child"
  });
  assert.equal(child.status, "idle", "Grok fires SubagentStop in the sub-agent's own session");
  const grokStop = new HookNormalizer().ingest("grok", { hook_event_name: "Stop", sessionId: "child", agentId: "child" });
  assert.equal(grokStop.status, "idle", "a Grok payload is always about its own session");
  const claude = new HookNormalizer().ingest("claude", { hook_event_name: "SubagentStop", session_id: "parent", agent_id: "a1" });
  assert.equal(claude.status, "running", "Claude fires it in the parent, which keeps working");
});

test("a grok sub-agent and its grok -p parent both end idle, whichever of SessionEnd and the turn end the scan sees", async () => {
  const { MonitorState } = await import("../src/projection/monitor-state.js");
  const { projectLocalSnapshot } = await import("../src/local-monitor.js");
  await withTempDirectory(async (root) => {
    const registry = new HookSessions({ claudeRoot: join(root, "projects"), grokRoot: join(root, "grok") });
    const state = new MonitorState();
    const at = Date.parse("2026-09-27T04:46:52Z");
    const pass = (nowMs) => state.setSessions(projectLocalSnapshot({ sessions: registry.merge([], nowMs) }).sessions);
    registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "parent", cwd: "/w" }, at);
    registry.record("grok", { hook_event_name: "UserPromptSubmit", sessionId: "child", cwd: "/w", subagentType: "general-purpose" }, at + 100);
    pass(at + 200);
    assert.equal(state.sessions.get("local:grok:child").status, "running");

    // The child's turn end, then its teardown.
    registry.record("grok", { hook_event_name: "SubagentStop", sessionId: "child", subagentType: "general-purpose" }, at + 3_000);
    pass(at + 3_100);
    assert.equal(state.sessions.get("local:grok:child").status, "idle", "SubagentStop settles the sub-agent");
    registry.record("grok", { hook_event_name: "SessionEnd", sessionId: "child", subagentType: "general-purpose" }, at + 3_200);
    pass(at + 3_300);
    assert.equal(state.historySessions.get("local:grok:child").status, "idle");

    // The parent's SessionEnd beats any sign of its turn end to the scan.
    registry.record("grok", { hook_event_name: "SessionEnd", sessionId: "parent" }, at + 6_000);
    pass(at + 6_100);
    const parent = state.historySessions.get("local:grok:parent");
    assert.equal(parent.status, "idle", "an ended session is not archived mid-turn");
    assert.equal(parent.turnId, null);
    assert.equal(parent.stopReason, "completed");
    assert.equal(state.sessions.has("local:grok:parent"), false);
  });
});
