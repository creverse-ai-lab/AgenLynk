import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { parseInstallerArgs, runInstaller } from "../src/installer.js";

const runtime = { nodeVersion: "22.0.0", platform: "darwin" };
const providers = [
  { id: "codex", agentInstalled: true, adapterInstalled: true, install: null },
  { id: "claude", agentInstalled: false, adapterInstalled: true, install: null }
];

test("installer parses a complete targeted installation", () => {
  const options = parseInstallerArgs(["--install-all", "--target", "codex", "--skip-health-check"]);
  assert.equal(options.installAdapters, true);
  assert.equal(options.installControl, true);
  assert.equal(options.installGuide, true);
  assert.equal(options.installSkill, true);
  assert.deepEqual(options.targets, ["codex"]);
  assert.equal(options.healthCheck, false);
  assert.throws(() => parseInstallerArgs(["--target", "unknown"]), /Unsupported installer target/);
});

test("installer persists and reuses its Control identity", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-identity-"));
  const statePath = join(directory, "install.json");
  const calls = [];
  let installed = false;
  const runCommand = async (command, args) => {
    calls.push([command, ...args]);
    if (args.includes("get")) {
      return installed
        ? { code: 0, stdout: "existing", stderr: "" }
        : { code: 1, stdout: "", stderr: "No MCP server named test found" };
    }
    if (args.includes("add")) installed = true;
    return { code: 0, stdout: "", stderr: "" };
  };
  const options = parseInstallerArgs(["--install-control", "--target", "codex", "--skip-health-check"]);
  try {
    const first = await runInstaller(options, { statePath, runtime, runCommand, detectProviders: async () => providers });
    const firstState = JSON.parse(await readFile(statePath, "utf8"));
    const second = await runInstaller(options, { statePath, runtime, runCommand, detectProviders: async () => providers });
    const secondState = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(firstState.identity.token, secondState.identity.token);
    assert.equal(firstState.identity.rootId, secondState.identity.rootId);
    assert.equal(first.identity.token, undefined);
    assert.equal(second.health.checked, false);
    assert.ok(calls.some((call) => call.includes("ACP_GATEWAY_CONTROL_TOKEN=" + firstState.identity.token)));
    assert.equal(calls.filter((call) => call.includes("add")).length, 1);
    assert.equal(second.actions[0].status, "unchanged");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer refuses to replace an unmanaged MCP entry without force", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-collision-"));
  const statePath = join(directory, "install.json");
  const runCommand = async (_command, args) => args.includes("get")
    ? { code: 0, stdout: "existing", stderr: "" }
    : { code: 0, stdout: "", stderr: "" };
  const options = parseInstallerArgs(["--install-control", "--target", "codex", "--skip-health-check"]);
  try {
    await assert.rejects(
      runInstaller(options, { statePath, runtime, runCommand, detectProviders: async () => providers }),
      /not managed by this installer/
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer dry-run does not create state or execute commands", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-dry-run-"));
  const statePath = join(directory, "install.json");
  let commandCalls = 0;
  const options = parseInstallerArgs(["--install-all", "--target", "codex", "--dry-run"]);
  try {
    const result = await runInstaller(options, {
      statePath,
      runtime,
      runCommand: async () => { commandCalls += 1; return { code: 0, stdout: "", stderr: "" }; },
      detectProviders: async () => providers
    });
    assert.equal(result.dryRun, true);
    assert.deepEqual(result.targets, { control: ["codex"], guide: ["codex"], skill: ["codex"] });
    assert.equal(commandCalls, 0);
    await assert.rejects(access(statePath), /ENOENT/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all defaults Control to one Main while Guide can target every detected agent", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-main-boundary-"));
  const statePath = join(directory, "install.json");
  const allProviders = providers.map((provider) => ({ ...provider, agentInstalled: true }));
  try {
    const result = await runInstaller(parseInstallerArgs(["--install-all", "--dry-run"]), {
      statePath,
      runtime,
      detectProviders: async () => allProviders
    });
    assert.deepEqual(result.targets, { control: ["codex"], guide: ["codex", "claude"], skill: ["codex"] });
    assert.equal(result.actions.filter((action) => action.name === "agent-acp").length, 1);
    assert.equal(result.actions.filter((action) => action.name === "agent-acp-guide").length, 2);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer copies and atomically updates the managed agent-delegator skill", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-skill-"));
  const statePath = join(directory, "install.json");
  const skillSource = join(directory, "source-skill");
  const codexSkillRoot = join(directory, "codex-skills");
  const skillDirectory = join(codexSkillRoot, "agent-delegator");
  const destination = join(skillDirectory, "SKILL.md");
  const options = parseInstallerArgs(["--install-skill", "--target", "codex"]);
  try {
    await mkdir(skillSource);
    await writeFile(join(skillSource, "SKILL.md"), "version-one\n", "utf8");
    const dependencies = {
      statePath,
      skillSource,
      skillRoots: { codex: codexSkillRoot },
      runtime,
      detectProviders: async () => providers
    };
    await runInstaller(options, dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-one\n");
    await writeFile(join(skillSource, "SKILL.md"), "version-two\n", "utf8");
    await runInstaller(options, dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-two\n");
    const state = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(state.managedSkills["codex:agent-delegator"].path, skillDirectory);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer health check authenticates through the Gateway client", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-health-"));
  const statePath = join(directory, "install.json");
  let rpcConfig;
  let rpcCall;
  const options = parseInstallerArgs(["--install-control", "--target", "codex"]);
  try {
    const result = await runInstaller(options, {
      statePath,
      runtime,
      detectProviders: async () => providers,
      runCommand: async (_command, args) => args.includes("get")
        ? { code: 1, stdout: "", stderr: "No MCP server named test found" }
        : { code: 0, stdout: "", stderr: "" },
      rpcFactory: (config) => {
        rpcConfig = config;
        return {
          async call(method, args) { rpcCall = { method, args }; return { ok: true, sessions: [] }; },
          close() {}
        };
      }
    });
    assert.equal(result.health.ok, true);
    assert.ok(rpcConfig.token.length >= 24);
    assert.match(rpcConfig.rootId, /^main-/);
    assert.deepEqual(rpcCall, { method: "session", args: { action: "list" } });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
