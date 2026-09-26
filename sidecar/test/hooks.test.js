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
    const installed = installHooks({ env });
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
    assert.ok(existsSync(join(env.AGENLYNK_HOME, "hooks", "agenlynk-hook.sh")), "the script is installed at a stable path");
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
    installHooks({ env, only: ["codex"] });
    const pending = hookStatus({ env, only: ["codex"] }).targets.codex;
    assert.equal(pending.needsTrust, true);
    assert.ok(pending.untrustedEvents.includes("PreToolUse"));

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
    // Our PreToolUse group went after the existing one, so its trust key is :1:0
    // and the other tool's :0:0 is untouched.
    assert.equal(hooks.PreToolUse.length, 2);
  });
});

test("a malformed config file is left untouched and a per-CLI opt-out survives restarts", async () => {
  await withTempDirectory(async (root) => {
    const { env } = await fakeHomes(root);
    await writeFile(join(env.CLAUDE_CONFIG_DIR, "settings.json"), "{ not json");
    const result = installHooks({ env });
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
  }
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
    const server = createServer((request, response) => {
      let body = "";
      request.on("data", (chunk) => { body += chunk; });
      request.on("end", () => {
        received.push({ url: request.url, token: request.headers["x-agenlynk-hook-token"], body });
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

      await runHook(["claude"], { env: { ...env, GROK_SESSION_ID: "g" }, stdin: payload });
      assert.equal(received.length, 1, "the Claude registration stays quiet inside Grok");
      await runHook(["grok"], { env: { ...env, GROK_SESSION_ID: "g" }, stdin: payload });
      assert.equal(received.at(-1).url, "/api/hooks/grok");

      await writeFile(endpoint, "AGENLYNK_HOOK_PORT=1; rm -rf /\nAGENLYNK_HOOK_TOKEN=x\n");
      assert.equal((await runHook(["codex"], { env, stdin: payload })).code, 0, "a tampered endpoint file is ignored");
      assert.equal(received.length, 2);
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
      const status = await (await fetch(`${ready.url}/api/hooks`, { headers })).json();
      assert.equal(status.receiving, true);
      assert.ok(Object.values(status.targets).every((target) => target.installed), "start installs hooks for every CLI present");

      const script = join(env.AGENLYNK_HOME, "hooks", "agenlynk-hook.sh");
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
