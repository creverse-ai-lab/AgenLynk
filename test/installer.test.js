import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { parseInstallerArgs, runInstaller } from "../src/installer.js";
import { GATEWAY_API_VERSION, UnsupportedGatewayApiVersionError } from "../src/gateway-api-version.js";
import { GATEWAY_BUILD_ID, GATEWAY_RUNTIME_ROOT, GATEWAY_VERSION } from "../src/version.js";

const runtime = { nodeVersion: "22.0.0", platform: "darwin" };
const providers = [
  { id: "codex", agentInstalled: true, adapterInstalled: true, install: null },
  { id: "claude", agentInstalled: false, adapterInstalled: true, install: null }
];
const emptyRegistryLoader = async () => ({
  registry: { version: "1.0.0", agents: [] },
  source: "network",
  stale: false
});

test("installer parses a complete targeted installation", () => {
  const options = parseInstallerArgs(["--install-all", "--target", "codex", "--skip-health-check"]);
  assert.equal(options.installAdapters, true);
  assert.equal(options.installAll, true);
  assert.equal(options.installControl, true);
  assert.equal(options.installGuide, true);
  assert.equal(options.installSkill, true);
  assert.deepEqual(options.targets, ["codex"]);
  assert.equal(options.healthCheck, false);
  assert.throws(() => parseInstallerArgs(["--target", "unknown"]), /Unsupported installer target/);
});

test("installer update preserves user-customized skills while refreshing runtime components", () => {
  const options = parseInstallerArgs(["--update"]);
  assert.equal(options.update, true);
  assert.equal(options.refreshRegistry, true);
  assert.equal(options.installAdapters, true);
  assert.equal(options.installControl, true);
  assert.equal(options.installGuide, true);
  assert.equal(options.installSkill, false);
  assert.equal(options.discoverAgents, true);
  assert.equal(options.restartDaemon, true);
});

test("installer parses standalone managed skill updates", () => {
  const options = parseInstallerArgs(["--update-skill", "--target", "codex", "--dry-run"]);
  assert.equal(options.installSkill, true);
  assert.equal(options.updateSkill, true);
  assert.equal(options.discoverAgents, false);
  assert.equal(options.installAdapters, false);
  assert.equal(options.restartDaemon, false);
  assert.throws(
    () => parseInstallerArgs(["--install-skill", "--update-skill"]),
    /cannot be combined/
  );
  assert.throws(
    () => parseInstallerArgs(["--install-all", "--update-skill"]),
    /cannot be combined/
  );
});

test("installer update preserves the previously installed front door", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-update-front-door-"));
  const statePath = join(directory, "install.json");
  const allProviders = providers.map((provider) => ({ ...provider, agentInstalled: true }));
  try {
    await writeFile(statePath, JSON.stringify({
      version: 1,
      identity: { token: "test-control-token-at-least-24-characters", rootId: "main-test" },
      managedMcp: {
        "claude:agent-acp": { agent: "claude", name: "agent-acp", kind: "control" },
        "codex:agent-acp-guide": { agent: "codex", name: "agent-acp-guide", kind: "guide" }
      },
      managedSkills: {},
      agentUpdates: { autoUpdate: true, notifications: true }
    }), "utf8");
    const result = await runInstaller(parseInstallerArgs(["--update", "--dry-run"]), {
      statePath,
      runtime,
      detectProviders: async () => allProviders,
      registryLoader: emptyRegistryLoader
    });
    assert.deepEqual(result.targets.control, ["claude"]);
    assert.deepEqual(result.targets.guide, ["codex", "claude"]);
    assert.deepEqual(result.targets.skill, []);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer front-door selection removes stale managed Control MCP entries", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-exclusive-front-door-"));
  const statePath = join(directory, "install.json");
  const calls = [];
  const allProviders = [
    { id: "codex", agentInstalled: true, adapterInstalled: true, install: null },
    { id: "claude", agentInstalled: true, adapterInstalled: true, install: null },
    { id: "grok", agentInstalled: true, adapterInstalled: true, install: null }
  ];
  try {
    await writeFile(statePath, JSON.stringify({
      version: 1,
      identity: { token: "test-control-token-at-least-24-characters", rootId: "main-test" },
      managedMcp: Object.fromEntries(allProviders.map(({ id }) => [
        `${id}:agent-acp`,
        { agent: id, name: "agent-acp", kind: "control" }
      ])),
      managedSkills: {},
      agentUpdates: { autoUpdate: true, notifications: true }
    }), "utf8");

    const result = await runInstaller(
      parseInstallerArgs(["--update", "--front-door", "codex", "--skip-health-check"]),
      {
        statePath,
        runtime,
        detectProviders: async () => allProviders,
        registryLoader: emptyRegistryLoader,
        restartGateway: async () => ({ performed: true, wasRunning: false }),
        runCommand: async (command, args) => {
          calls.push([command, ...args]);
          if (command === "grok" && args.slice(0, 2).join(" ") === "mcp list") {
            return { code: 0, stdout: JSON.stringify([{ name: "agent-acp" }]), stderr: "" };
          }
          if (args.slice(0, 2).join(" ") === "mcp get") {
            return args.includes("agent-acp")
              ? { code: 0, stdout: "existing", stderr: "" }
              : { code: 1, stdout: "", stderr: "not found" };
          }
          return { code: 0, stdout: "", stderr: "" };
        }
      }
    );

    assert.deepEqual(result.targets.control, ["codex"]);
    assert.ok(calls.some((call) => call[0] === "claude" && call.slice(1).join(" ") === "mcp remove --scope user agent-acp"));
    assert.ok(calls.some((call) => call[0] === "grok" && call.slice(1).join(" ") === "mcp remove agent-acp"));
    const saved = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(saved.frontDoor, "codex");
    assert.ok(saved.managedMcp["codex:agent-acp"]);
    assert.equal(saved.managedMcp["codex:agent-acp"].formatVersion, 2);
    assert.equal(saved.managedMcp["claude:agent-acp"], undefined);
    assert.equal(saved.managedMcp["grok:agent-acp"], undefined);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer parses persistent ACP update policy controls", () => {
  const options = parseInstallerArgs([
    "--agent-auto-update", "off",
    "--agent-update-notifications", "on",
    "--dry-run"
  ]);
  assert.equal(options.agentAutoUpdate, false);
  assert.equal(options.agentUpdateNotifications, true);
  assert.equal(options.restartDaemon, true);
  assert.throws(() => parseInstallerArgs(["--agent-auto-update", "sometimes"]), /requires on or off/);
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
    assert.ok(calls.some((call) => call.includes(`ACP_GATEWAY_INSTALL_STATE=${statePath}`)));
    assert.equal(calls.flat().some((arg) => String(arg).includes(firstState.identity.token)), false);
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
      detectProviders: async () => providers,
      registryLoader: emptyRegistryLoader,
      skillRoots: { codex: join(directory, "codex-skills") }
    });
    assert.equal(result.dryRun, true);
    assert.deepEqual(result.targets, { control: ["codex"], guide: ["codex"], skill: ["codex"] });
    assert.equal(commandCalls, 0);
    await assert.rejects(access(statePath), /ENOENT/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all uses one selected front door while Guide reaches every agent", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-main-boundary-"));
  const statePath = join(directory, "install.json");
  const allProviders = [
    ...providers.map((provider) => ({ ...provider, agentInstalled: true })),
    { id: "grok", agentInstalled: true, adapterInstalled: true, install: null }
  ];
  try {
    const result = await runInstaller(parseInstallerArgs(["--install-all", "--front-door", "claude", "--dry-run"]), {
      statePath,
      runtime,
      detectProviders: async () => allProviders,
      registryLoader: emptyRegistryLoader,
      skillRoots: {
        codex: join(directory, "codex-skills"),
        claude: join(directory, "claude-skills"),
        grok: join(directory, "grok-skills")
      }
    });
    assert.deepEqual(result.targets, {
      control: ["claude"],
      guide: ["codex", "claude", "grok"],
      skill: ["codex", "claude", "grok"]
    });
    assert.equal(result.actions.filter((action) => action.name === "agent-acp").length, 1);
    assert.equal(result.actions.filter((action) => action.name === "agent-acp-guide").length, 3);
    assert.equal(result.actions.filter((action) => action.type === "skill").length, 3);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all front door validation is explicit", () => {
  assert.equal(parseInstallerArgs(["--install-all", "--front-door", "grok"]).frontDoor, "grok");
  assert.throws(() => parseInstallerArgs(["--install-all", "--front-door", "auggie"]), /requires codex, claude, or grok/);
  assert.throws(() => parseInstallerArgs(["--front-door", "claude"]), /only be used with --install-all/);
  assert.throws(
    () => parseInstallerArgs(["--install-all", "--front-door", "claude", "--target", "codex"]),
    /cannot be combined/
  );
});

test("installer keeps reinstall separate from managed skill updates", async () => {
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
    const unchanged = await runInstaller(parseInstallerArgs(["--update-skill", "--target", "codex"]), dependencies);
    assert.equal(unchanged.actions.find((action) => action.type === "skill").status, "up-to-date");
    await writeFile(join(skillSource, "SKILL.md"), "version-two\n", "utf8");
    const reinstall = await runInstaller(options, dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-one\n");
    assert.equal(reinstall.actions.find((action) => action.type === "skill").status, "already-installed");
    assert.match(reinstall.warnings.join("\n"), /--update-skill/);

    const updated = await runInstaller(parseInstallerArgs(["--update-skill", "--target", "codex"]), dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-two\n");
    assert.equal(updated.actions.find((action) => action.type === "skill").status, "updated");
    const state = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(state.managedSkills["codex:agent-delegator"].path, skillDirectory);
    assert.match(state.managedSkills["codex:agent-delegator"].sourceDigest, /^[a-f0-9]{64}$/);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("managed skill updates preserve local customization unless forced", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-skill-custom-"));
  const statePath = join(directory, "install.json");
  const skillSource = join(directory, "source-skill");
  const codexSkillRoot = join(directory, "codex-skills");
  const destination = join(codexSkillRoot, "agent-delegator", "SKILL.md");
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
    await runInstaller(parseInstallerArgs(["--install-skill", "--target", "codex"]), dependencies);
    await writeFile(destination, "local-customization\n", "utf8");
    await writeFile(join(skillSource, "SKILL.md"), "version-two\n", "utf8");

    const preserved = await runInstaller(parseInstallerArgs(["--update-skill"]), dependencies);
    assert.equal(await readFile(destination, "utf8"), "local-customization\n");
    assert.equal(preserved.actions.find((action) => action.type === "skill").status, "customized");

    const forced = await runInstaller(parseInstallerArgs(["--update-skill", "--force"]), dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-two\n");
    assert.equal(forced.actions.find((action) => action.type === "skill").status, "updated");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("managed skill updates require recorded state and protect legacy installs", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-skill-legacy-"));
  const statePath = join(directory, "install.json");
  const skillSource = join(directory, "source-skill");
  const codexSkillRoot = join(directory, "codex-skills");
  const skillDirectory = join(codexSkillRoot, "agent-delegator");
  const destination = join(skillDirectory, "SKILL.md");
  const dependencies = {
    statePath,
    skillSource,
    skillRoots: { codex: codexSkillRoot },
    runtime,
    detectProviders: async () => providers
  };
  try {
    await mkdir(skillSource);
    await writeFile(join(skillSource, "SKILL.md"), "version-two\n", "utf8");
    await assert.rejects(
      runInstaller(parseInstallerArgs(["--update-skill"]), dependencies),
      /requires an installer-managed skill/
    );

    await mkdir(skillDirectory, { recursive: true });
    await writeFile(destination, "version-two\n", "utf8");
    await writeFile(statePath, JSON.stringify({
      version: 1,
      managedMcp: {},
      managedSkills: {
        "codex:agent-delegator": {
          agent: "codex",
          name: "agent-delegator",
          path: skillDirectory,
          installedAt: "2026-01-01T00:00:00.000Z"
        }
      },
      agentUpdates: { autoUpdate: true, notifications: true }
    }), "utf8");

    const protectedLegacy = await runInstaller(parseInstallerArgs(["--update-skill"]), dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-two\n");
    assert.equal(protectedLegacy.actions.find((action) => action.type === "skill").status, "legacy-unverified");

    await writeFile(destination, "legacy-copy\n", "utf8");
    await runInstaller(parseInstallerArgs(["--update-skill", "--force"]), dependencies);
    assert.equal(await readFile(destination, "utf8"), "version-two\n");
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
      skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
      detectProviders: async () => providers,
      runCommand: async (_command, args) => args.includes("get")
        ? { code: 1, stdout: "", stderr: "No MCP server named test found" }
        : { code: 0, stdout: "", stderr: "" },
      rpcFactory: (config) => {
        rpcConfig = config;
        return {
          async call(method, args) {
            rpcCall = { method, args };
            return { ok: true, gatewayVersion: GATEWAY_VERSION, gatewayBuildId: GATEWAY_BUILD_ID };
          },
          close() {}
        };
      }
    });
    assert.equal(result.health.ok, true);
    assert.equal(result.health.version, GATEWAY_VERSION);
    assert.equal(result.health.buildId, GATEWAY_BUILD_ID);
    assert.ok(rpcConfig.token.length >= 24);
    assert.match(rpcConfig.rootId, /^main-/);
    assert.deepEqual(rpcCall, { method: "setup", args: {} });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all replaces an older daemon when health reports a version mismatch", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-version-upgrade-"));
  const statePath = join(directory, "install.json");
  const setupVersions = ["0.2.0", GATEWAY_VERSION];
  let restartCalls = 0;
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--install-all", "--target", "codex"]),
      {
        statePath,
        runtime,
        skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
        detectProviders: async () => providers,
        registryLoader: emptyRegistryLoader,
        registryDiscover: async () => [],
        runCommand: async (_command, args) => {
          if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        },
        restartGateway: async () => {
          restartCalls += 1;
          return { performed: true, wasRunning: true, graceful: false, version: GATEWAY_VERSION };
        },
        rpcFactory: () => ({
          async call(method) {
            assert.equal(method, "setup");
            return { ok: true, gatewayVersion: setupVersions.shift(), gatewayBuildId: GATEWAY_BUILD_ID };
          },
          close() {}
        })
      }
    );
    assert.equal(restartCalls, 1);
    assert.equal(result.restart.automatic, true);
    assert.equal(result.restart.graceful, false);
    assert.equal(result.health.version, GATEWAY_VERSION);
    assert.equal(result.health.ok, true);
    assert.equal(setupVersions.length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all replaces a same-version daemon with a stale or missing build id", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-build-upgrade-"));
  const statePath = join(directory, "install.json");
  const setupResponses = [
    { ok: true, gatewayVersion: GATEWAY_VERSION },
    { ok: true, gatewayVersion: GATEWAY_VERSION, gatewayBuildId: GATEWAY_BUILD_ID }
  ];
  let restartCalls = 0;
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--install-all", "--target", "codex"]),
      {
        statePath,
        runtime,
        skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
        detectProviders: async () => providers,
        registryLoader: emptyRegistryLoader,
        registryDiscover: async () => [],
        runCommand: async (_command, args) => {
          if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        },
        restartGateway: async () => {
          restartCalls += 1;
          return {
            performed: true,
            wasRunning: true,
            graceful: true,
            version: GATEWAY_VERSION,
            buildId: GATEWAY_BUILD_ID
          };
        },
        rpcFactory: () => ({
          async call(method) {
            assert.equal(method, "setup");
            return setupResponses.shift();
          },
          close() {}
        })
      }
    );
    assert.equal(restartCalls, 1);
    assert.equal(result.actions.find((action) => action.reason === "build-mismatch")?.fromBuildId, null);
    assert.equal(result.health.buildId, GATEWAY_BUILD_ID);
    assert.equal(result.health.ok, true);
    assert.equal(setupResponses.length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer update invokes daemon replacement before version health", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-update-"));
  const statePath = join(directory, "install.json");
  let restartCalls = 0;
  let healthCalls = 0;
  try {
    const result = await runInstaller(parseInstallerArgs(["--update", "--target", "codex"]), {
      statePath,
      runtime,
      skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
      detectProviders: async () => providers,
      registryLoader: emptyRegistryLoader,
      registryDiscover: async () => [],
      runCommand: async (_command, args) => {
        if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
        if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
        return { code: 0, stdout: "", stderr: "" };
      },
      restartGateway: async () => {
        restartCalls += 1;
        return { performed: true, wasRunning: true, graceful: true, version: GATEWAY_VERSION };
      },
      rpcFactory: () => ({
        async call(method) {
          assert.equal(method, "setup");
          healthCalls += 1;
          return { ok: true, gatewayVersion: GATEWAY_VERSION, gatewayBuildId: GATEWAY_BUILD_ID };
        },
        close() {}
      })
    });
    assert.equal(restartCalls, 1);
    assert.equal(healthCalls, 1);
    assert.equal(result.restart.version, GATEWAY_VERSION);
    assert.equal(result.health.ok, true);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all does not restart a compatible daemon serving from a different runtimeRoot on version/build mismatch alone", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-cross-root-"));
  const statePath = join(directory, "install.json");
  let restartCalls = 0;
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--install-all", "--target", "codex"]),
      {
        statePath,
        runtime,
        skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
        detectProviders: async () => providers,
        registryLoader: emptyRegistryLoader,
        registryDiscover: async () => [],
        runCommand: async (_command, args) => {
          if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        },
        restartGateway: async () => {
          restartCalls += 1;
          return { performed: true, wasRunning: true, graceful: true, version: GATEWAY_VERSION };
        },
        rpcFactory: () => ({
          async call(method) {
            assert.equal(method, "setup");
            return {
              ok: true,
              gatewayVersion: "0.9.0",
              gatewayBuildId: "other-build",
              gatewayApiVersion: GATEWAY_API_VERSION,
              runtimeRoot: "/opt/other-lynk-install/runtime/versions/0.9.0-other-build"
            };
          },
          close() {}
        })
      }
    );
    assert.equal(restartCalls, 0, "a different, compatible runtimeRoot must never be restarted for version/build mismatch alone");
    assert.equal(result.health.ok, true);
    assert.equal(result.health.version, "0.9.0");
    assert.equal(result.health.runtimeRoot, "/opt/other-lynk-install/runtime/versions/0.9.0-other-build");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

async function runInstallerWithSetupResponse(directory, setupResponse, { restartGateway } = {}) {
  const statePath = join(directory, "install.json");
  let restartCalls = 0;
  const result = runInstaller(
    parseInstallerArgs(["--install-all", "--target", "codex"]),
    {
      statePath,
      runtime,
      skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
      detectProviders: async () => providers,
      registryLoader: emptyRegistryLoader,
      registryDiscover: async () => [],
      runCommand: async (_command, args) => {
        if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
        if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
        return { code: 0, stdout: "", stderr: "" };
      },
      restartGateway: restartGateway ?? (async () => {
        restartCalls += 1;
        return { performed: true, wasRunning: true, graceful: true, version: GATEWAY_VERSION };
      }),
      rpcFactory: () => ({
        async call(method) {
          assert.equal(method, "setup");
          return setupResponse;
        },
        close() {}
      })
    }
  );
  return { result, restartCallsRef: () => restartCalls };
}

test("install-all fails with a structured error (higher major) when the daemon reports an unsupported Gateway API major", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-unsupported-api-higher-"));
  try {
    const { result, restartCallsRef } = await runInstallerWithSetupResponse(directory, {
      ok: true,
      gatewayVersion: "9.9.9",
      gatewayBuildId: "future-build",
      gatewayApiVersion: GATEWAY_API_VERSION + 1,
      runtimeRoot: "/opt/future-lynk-install/runtime/versions/9.9.9-future-build"
    });
    await assert.rejects(result, (error) => {
      assert.ok(error instanceof UnsupportedGatewayApiVersionError);
      assert.equal(error.code, "UNSUPPORTED_GATEWAY_API_VERSION");
      assert.equal(error.reportedGatewayApiVersion, GATEWAY_API_VERSION + 1);
      assert.equal(error.supportedGatewayApiVersion, GATEWAY_API_VERSION);
      assert.equal(error.requiredGatewayApiVersion, GATEWAY_API_VERSION + 1);
      assert.match(error.message, /Gateway API version/);
      return true;
    });
    assert.equal(restartCallsRef(), 0, "an unsupported API major must fail explicitly, not trigger a restart attempt");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all fails with a structured error (lower major) and never restarts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-unsupported-api-lower-"));
  try {
    const { result, restartCallsRef } = await runInstallerWithSetupResponse(directory, {
      ok: true,
      gatewayVersion: "0.1.0",
      gatewayBuildId: "ancient-build",
      gatewayApiVersion: GATEWAY_API_VERSION - 1,
      runtimeRoot: "/opt/ancient-lynk-install/runtime/versions/0.1.0-ancient-build"
    });
    await assert.rejects(result, (error) => {
      assert.ok(error instanceof UnsupportedGatewayApiVersionError);
      assert.equal(error.code, "UNSUPPORTED_GATEWAY_API_VERSION");
      assert.equal(error.reportedGatewayApiVersion, GATEWAY_API_VERSION - 1);
      assert.equal(error.supportedGatewayApiVersion, GATEWAY_API_VERSION);
      // A lower major has no single unambiguous "required" version, so it is omitted.
      assert.equal(error.requiredGatewayApiVersion, undefined);
      return true;
    });
    assert.equal(restartCallsRef(), 0, "a lower API major must fail explicitly, not trigger a restart attempt");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all fails with a structured error (non-integer/invalid major) and never restarts", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-unsupported-api-invalid-"));
  try {
    const { result, restartCallsRef } = await runInstallerWithSetupResponse(directory, {
      ok: true,
      gatewayVersion: "1.0.0",
      gatewayBuildId: "weird-build",
      gatewayApiVersion: "1",
      runtimeRoot: "/opt/weird-lynk-install/runtime/versions/1.0.0-weird-build"
    });
    await assert.rejects(result, (error) => {
      assert.ok(error instanceof UnsupportedGatewayApiVersionError);
      assert.equal(error.code, "UNSUPPORTED_GATEWAY_API_VERSION");
      assert.equal(error.reportedGatewayApiVersion, "1");
      assert.equal(error.requiredGatewayApiVersion, undefined);
      return true;
    });
    assert.equal(restartCallsRef(), 0, "a non-integer/invalid API major must fail explicitly, not trigger a restart attempt");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all treats a missing gatewayApiVersion as legacy-compatible (not unsupported)", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-legacy-api-"));
  try {
    const { result } = await runInstallerWithSetupResponse(directory, {
      ok: true,
      gatewayVersion: GATEWAY_VERSION,
      gatewayBuildId: GATEWAY_BUILD_ID
    });
    const outcome = await result;
    assert.equal(outcome.health.ok, true);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all fails with a structured error when a same-runtimeRoot daemon reports an unsupported major even after an automatic restart", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-unsupported-api-post-restart-"));
  try {
    const setupResponses = [
      {
        ok: true,
        gatewayVersion: "0.9.0",
        gatewayBuildId: "stale-build",
        gatewayApiVersion: GATEWAY_API_VERSION,
        runtimeRoot: GATEWAY_RUNTIME_ROOT
      },
      {
        ok: true,
        gatewayVersion: GATEWAY_VERSION,
        gatewayBuildId: GATEWAY_BUILD_ID,
        gatewayApiVersion: GATEWAY_API_VERSION + 1,
        runtimeRoot: GATEWAY_RUNTIME_ROOT
      }
    ];
    let restartCalls = 0;
    const result = runInstaller(
      parseInstallerArgs(["--install-all", "--target", "codex"]),
      {
        statePath: join(directory, "install.json"),
        runtime,
        skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
        detectProviders: async () => providers,
        registryLoader: emptyRegistryLoader,
        registryDiscover: async () => [],
        runCommand: async (_command, args) => {
          if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        },
        restartGateway: async () => {
          restartCalls += 1;
          return { performed: true, wasRunning: true, graceful: true, version: GATEWAY_VERSION, buildId: GATEWAY_BUILD_ID };
        },
        rpcFactory: () => ({
          async call(method) {
            assert.equal(method, "setup");
            return setupResponses.shift();
          },
          close() {}
        })
      }
    );
    await assert.rejects(result, (error) => {
      assert.ok(error instanceof UnsupportedGatewayApiVersionError);
      assert.equal(error.reportedGatewayApiVersion, GATEWAY_API_VERSION + 1);
      return true;
    });
    assert.equal(restartCalls, 1, "the same-root stale daemon is still restarted once before the post-restart response is re-validated");
    assert.equal(setupResponses.length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("install-all still replaces a same-runtimeRoot stale daemon on version/build mismatch", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-same-root-"));
  const statePath = join(directory, "install.json");
  const setupResponses = [
    {
      ok: true,
      gatewayVersion: "0.9.0",
      gatewayBuildId: "stale-build",
      gatewayApiVersion: GATEWAY_API_VERSION,
      runtimeRoot: GATEWAY_RUNTIME_ROOT
    },
    {
      ok: true,
      gatewayVersion: GATEWAY_VERSION,
      gatewayBuildId: GATEWAY_BUILD_ID,
      gatewayApiVersion: GATEWAY_API_VERSION,
      runtimeRoot: GATEWAY_RUNTIME_ROOT
    }
  ];
  let restartCalls = 0;
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--install-all", "--target", "codex"]),
      {
        statePath,
        runtime,
        skillRoots: { codex: join(directory, "codex-skills"), default: join(directory, "shared-skills") },
        detectProviders: async () => providers,
        registryLoader: emptyRegistryLoader,
        registryDiscover: async () => [],
        runCommand: async (_command, args) => {
          if (args.includes("get")) return { code: 1, stdout: "", stderr: "not found" };
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        },
        restartGateway: async () => {
          restartCalls += 1;
          return { performed: true, wasRunning: true, graceful: true, version: GATEWAY_VERSION, buildId: GATEWAY_BUILD_ID };
        },
        rpcFactory: () => ({
          async call(method) {
            assert.equal(method, "setup");
            return setupResponses.shift();
          },
          close() {}
        })
      }
    );
    assert.equal(restartCalls, 1, "a stale daemon reporting our own runtimeRoot must still be restarted");
    assert.equal(result.health.ok, true);
    assert.equal(result.health.version, GATEWAY_VERSION);
    assert.equal(setupResponses.length, 0);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer downloads and registers an explicitly selected official ACP agent", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-registry-"));
  const statePath = join(directory, "install.json");
  const providerRegistryPath = join(directory, "providers.json");
  const calls = [];
  const officialRegistry = {
    version: "1.0.0",
    agents: [{
      id: "gemini",
      name: "Gemini CLI",
      version: "0.53.0",
      distribution: { npx: { package: "@google/gemini-cli@0.53.0", args: ["--acp"] } }
    }]
  };
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--registry-agent", "gemini", "--skip-health-check"]),
      {
        statePath,
        providerRegistryPath,
        runtime: { ...runtime, arch: "arm64" },
        detectProviders: async () => providers,
        registryLoader: async () => ({ registry: officialRegistry, source: "network", stale: false }),
        registryDiscover: async () => [],
        runCommand: async (command, args) => {
          calls.push([command, ...args]);
          if (args.includes("--json")) return { code: 0, stdout: "{\"dependencies\":{}}", stderr: "" };
          return { code: 0, stdout: "", stderr: "" };
        }
      }
    );
    assert.deepEqual(result.registry.configured, ["gemini"]);
    assert.ok(calls.some((call) => call.join(" ") === "npm install --global @google/gemini-cli@0.53.0"));
    const saved = JSON.parse(await readFile(providerRegistryPath, "utf8"));
    assert.deepEqual(saved.providers.gemini.args, ["--yes", "@google/gemini-cli@0.53.0", "--acp"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer plans the delegation skill for every discovered agent and deduplicates shared roots", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-all-skills-"));
  const statePath = join(directory, "install.json");
  const sharedRoot = join(directory, "shared-skills");
  const discovered = [
    {
      id: "auggie",
      registryId: "auggie",
      name: "Auggie",
      version: "1.0.0",
      distribution: { type: "npx", package: "auggie@1.0.0", args: ["--acp"], env: {} },
      foundCommand: "auggie",
      packageInstalled: true
    },
    {
      id: "other-agent",
      registryId: "other-agent",
      name: "Other Agent",
      version: "1.0.0",
      distribution: { type: "npx", package: "other-agent@1.0.0", args: [], env: {} },
      foundCommand: "other-agent",
      packageInstalled: true
    },
    {
      id: "second-agent",
      registryId: "second-agent",
      name: "Second Agent",
      version: "1.0.0",
      distribution: { type: "npx", package: "second-agent@1.0.0", args: [], env: {} },
      foundCommand: "second-agent",
      packageInstalled: true
    }
  ];
  try {
    const result = await runInstaller(parseInstallerArgs(["--install-skill", "--target", "all", "--dry-run"]), {
      statePath,
      runtime,
      detectProviders: async () => providers,
      registryLoader: async () => ({ registry: { version: "1.0.0", agents: [] }, source: "network", stale: false }),
      registryDiscover: async () => discovered,
      skillRoots: {
        codex: join(directory, "codex-skills"),
        auggie: join(directory, "augment-skills"),
        default: sharedRoot
      }
    });
    assert.deepEqual(result.targets.skill, ["auggie", "other-agent", "second-agent", "codex"]);
    const skills = result.actions.filter((action) => action.type === "skill");
    assert.equal(skills.length, 4);
    assert.equal(skills.find((item) => item.agent === "auggie").destination, join(directory, "augment-skills", "agent-delegator"));
    assert.equal(skills.find((item) => item.agent === "second-agent").status, "shared");
    assert.equal(skills.find((item) => item.agent === "second-agent").sharedWith, "other-agent");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer registers Control and Guide MCPs for Grok and Auggie", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-extra-mcp-"));
  const statePath = join(directory, "install.json");
  const calls = [];
  const extraProviders = [
    { id: "codex", agentInstalled: false, adapterInstalled: false, install: null },
    { id: "claude", agentInstalled: false, adapterInstalled: false, install: null },
    { id: "grok", agentInstalled: true, adapterInstalled: true, install: null },
    { id: "auggie", agentInstalled: true, adapterInstalled: true, install: null }
  ];
  try {
    const result = await runInstaller(
      parseInstallerArgs(["--install-control", "--install-guide", "--target", "all", "--skip-health-check"]),
      {
        statePath,
        runtime,
        detectProviders: async () => extraProviders,
        runCommand: async (command, args) => {
          calls.push([command, ...args]);
          if (args.join(" ") === "mcp list --json") {
            return {
              code: 0,
              stdout: command === "grok" ? "[]" : '{"servers":[]}',
              stderr: ""
            };
          }
          return { code: 0, stdout: "", stderr: "" };
        }
      }
    );
    assert.deepEqual(result.targets.control, ["codex", "claude", "grok", "auggie"]);
    assert.ok(calls.some((call) => call[0] === "grok" && call.slice(1, 5).join(" ") === "mcp add --scope user"));
    assert.ok(calls.some((call) => call[0] === "auggie" && call[1] === "mcp" && call[2] === "add-json"));
    const state = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(JSON.stringify(result.actions).includes(state.identity.token), false);
    assert.ok(JSON.stringify(result.actions).includes(`ACP_GATEWAY_INSTALL_STATE=${statePath}`));
    assert.ok(state.managedMcp["grok:agent-acp"]);
    assert.ok(state.managedMcp["grok:agent-acp-guide"]);
    assert.ok(state.managedMcp["auggie:agent-acp"]);
    assert.ok(state.managedMcp["auggie:agent-acp-guide"]);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("installer places the Claude MCP name before variadic environment arguments", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-installer-claude-mcp-"));
  const statePath = join(directory, "install.json");
  const calls = [];
  const claudeProviders = providers.map((provider) => ({
    ...provider,
    agentInstalled: provider.id === "claude"
  }));
  try {
    await runInstaller(
      parseInstallerArgs(["--install-control", "--target", "claude", "--skip-health-check"]),
      {
        statePath,
        runtime,
        detectProviders: async () => claudeProviders,
        runCommand: async (command, args) => {
          calls.push([command, ...args]);
          if (args.slice(0, 2).join(" ") === "mcp get") {
            return { code: 1, stdout: "", stderr: "No MCP server named agent-acp found" };
          }
          return { code: 0, stdout: "", stderr: "" };
        }
      }
    );
    const add = calls.find((call) => call[0] === "claude" && call[1] === "mcp" && call[2] === "add");
    assert.ok(add);
    assert.deepEqual(add.slice(1, 6), ["mcp", "add", "--scope", "user", "agent-acp"]);
    assert.ok(add.indexOf("agent-acp") < add.indexOf("-e"));
    assert.equal(add[add.indexOf("-e") + 1], `ACP_GATEWAY_INSTALL_STATE=${statePath}`);
    const state = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(add.some((arg) => String(arg).includes(state.identity.token)), false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
