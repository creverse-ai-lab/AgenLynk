import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { accessSync, constants } from "node:fs";
import { access, chmod, cp, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { detectProviders } from "./providers.js";
import {
  defaultProviderRegistryPath,
  discoverRegistryAgents,
  installedGlobalNpmPackages,
  loadOfficialRegistry,
  mergeProviderDefinitions,
  providerDefinition,
  selectDistribution
} from "./acp-registry.js";
import { GatewayRpcClient } from "./socket-rpc.js";

const CONTROL_NAME = "agent-acp";
const GUIDE_NAME = "agent-acp-guide";
const DELEGATOR_SKILL_NAME = "agent-delegator";
const SUPPORTED_TARGETS = new Set(["codex", "claude"]);
const sourceDirectory = dirname(fileURLToPath(import.meta.url));
const bundledSkillSource = join(dirname(sourceDirectory), "skills", DELEGATOR_SKILL_NAME);

export function defaultInstallStatePath() {
  return process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
}

export function parseInstallerArgs(argv) {
  const options = {
    installAdapters: false,
    installControl: false,
    installGuide: false,
    installSkill: false,
    discoverAgents: false,
    registryAgents: [],
    offline: false,
    refreshRegistry: false,
    rotateToken: false,
    dryRun: false,
    force: false,
    healthCheck: true,
    showSecrets: false,
    allTargets: false,
    targets: []
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--install-all") {
      options.installAdapters = true;
      options.installControl = true;
      options.installGuide = true;
      options.installSkill = true;
      options.discoverAgents = true;
    } else if (arg === "--install-adapters") {
      options.installAdapters = true;
      options.discoverAgents = true;
    } else if (arg === "--discover-agents") options.discoverAgents = true;
    else if (arg === "--offline") options.offline = true;
    else if (arg === "--refresh-registry") options.refreshRegistry = true;
    else if (arg === "--registry-agent") {
      const id = argv[++index];
      if (!id) throw new Error("--registry-agent requires an ACP registry agent id");
      options.registryAgents.push(id);
      options.discoverAgents = true;
      options.installAdapters = true;
    } else if (arg.startsWith("--registry-agent=")) {
      options.registryAgents.push(arg.slice("--registry-agent=".length));
      options.discoverAgents = true;
      options.installAdapters = true;
    } else if (arg === "--install-control") options.installControl = true;
    else if (arg === "--install-guide") options.installGuide = true;
    else if (arg === "--install-skill") {
      options.installSkill = true;
      options.discoverAgents = true;
    }
    else if (arg === "--rotate-token") {
      options.rotateToken = true;
      options.installControl = true;
    } else if (arg === "--dry-run") options.dryRun = true;
    else if (arg === "--force") options.force = true;
    else if (arg === "--skip-health-check") options.healthCheck = false;
    else if (arg === "--show-secrets") options.showSecrets = true;
    else if (arg === "--target") {
      const target = argv[++index];
      if (!target) throw new Error("--target requires codex, claude, or all");
      options.targets.push(target);
    } else if (arg.startsWith("--target=")) options.targets.push(arg.slice("--target=".length));
    else if (arg === "--help" || arg === "-h") options.help = true;
    else throw new Error(`Unknown installer option: ${arg}`);
  }
  if (options.targets.includes("all")) {
    options.allTargets = true;
    options.targets = ["codex", "claude"];
  }
  options.targets = [...new Set(options.targets)];
  options.registryAgents = [...new Set(options.registryAgents)];
  for (const id of options.registryAgents) {
    if (!/^[a-z0-9][a-z0-9._-]*$/.test(id)) throw new Error(`Invalid ACP registry agent id: ${id || "<empty>"}`);
  }
  for (const target of options.targets) {
    if (!SUPPORTED_TARGETS.has(target)) throw new Error(`Unsupported installer target: ${target}`);
  }
  return options;
}

export async function runInstaller(options, dependencies = {}) {
  const statePath = dependencies.statePath ?? defaultInstallStatePath();
  const detect = dependencies.detectProviders ?? detectProviders;
  const run = dependencies.runCommand ?? runCommand;
  const makeRpc = dependencies.rpcFactory ?? ((config) => new GatewayRpcClient(config));
  const skillSource = dependencies.skillSource ?? bundledSkillSource;
  const registryLoader = dependencies.registryLoader ?? loadOfficialRegistry;
  const registryDiscover = dependencies.registryDiscover ?? discoverRegistryAgents;
  const providerRegistryPath = dependencies.providerRegistryPath ?? defaultProviderRegistryPath();
  const skillRoots = dependencies.skillRoots ?? {
    codex: join(process.env.CODEX_HOME || join(homedir(), ".codex"), "skills"),
    claude: join(process.env.CLAUDE_HOME || join(homedir(), ".claude"), "skills"),
    grok: join(process.env.GROK_HOME || join(homedir(), ".grok"), "skills"),
    auggie: join(process.env.AUGMENT_HOME || join(homedir(), ".augment"), "skills"),
    default: join(homedir(), ".agents", "skills")
  };
  const runtime = dependencies.runtime ?? { nodeVersion: process.versions.node, platform: process.platform };
  preflight(runtime);

  const initialProviders = await detect();
  const actions = [];
  const warnings = [];
  let state = await readInstallState(statePath);
  let registry = { checked: false, source: null, available: 0, discovered: [], configured: [] };

  if (options.discoverAgents) {
    try {
      const loaded = await registryLoader({
        offline: options.offline,
        refresh: options.refreshRegistry,
        persist: !options.dryRun
      });
      const installedPackages = options.dryRun ? new Set() : await installedGlobalNpmPackages(run);
      const discovered = await registryDiscover(loaded.registry, {
        platform: runtime.platform,
        arch: runtime.arch ?? process.arch,
        installedPackages
      });
      const selected = new Map(discovered.map((item) => [item.registryId, item]));
      for (const id of options.registryAgents) {
        const agent = loaded.registry.agents.find((item) => item.id === id);
        if (!agent) throw new Error(`ACP registry agent not found: ${id}`);
        if (selected.has(id)) continue;
        const distribution = selectDistribution(agent);
        if (!distribution) throw new Error(`${id} has no distribution for this platform`);
        if (distribution.type === "binary") throw new Error(`${id} is binary-only and was not found locally; install its official binary first`);
        selected.set(id, {
          id: id === "claude-acp" ? "claude" : id === "codex-acp" ? "codex" : id === "grok-build" ? "grok" : id,
          registryId: id,
          name: agent.name,
          version: agent.version,
          distribution,
          foundCommand: null,
          packageInstalled: false
        });
      }
      const matches = [...selected.values()];
      const definitions = matches.map(providerDefinition);
      for (const match of matches) {
        const definition = definitions.find((item) => item.registryId === match.registryId);
        actions.push({
          type: "registry-provider",
          provider: definition.id,
          registryId: definition.registryId,
          version: definition.registryVersion,
          distribution: match.distribution.type,
          command: definition.command,
          args: definition.args
        });
        if (options.installAdapters && ["npx", "uvx"].includes(match.distribution.type)) {
          const command = match.distribution.type === "npx" ? "npm" : "uv";
          const args = match.distribution.type === "npx"
            ? ["install", "--global", match.distribution.package]
            : ["tool", "install", "--force", match.distribution.package];
          actions.push({ type: "registry-download", provider: definition.id, command, args });
          if (!options.dryRun) {
            await requireSuccess(run, command, args, `download ${match.registryId} from the ACP registry distribution`);
          }
        }
      }
      if (!options.dryRun && definitions.length) await mergeProviderDefinitions(providerRegistryPath, definitions);
      if (loaded.warning) warnings.push(loaded.warning);
      registry = {
        checked: true,
        source: loaded.source,
        stale: loaded.stale,
        available: loaded.registry.agents.length,
        discovered: matches.map((item) => item.registryId),
        configured: definitions.map((item) => item.id),
        providerRegistryPath
      };
    } catch (error) {
      if (options.registryAgents.length) throw error;
      warnings.push(error.message);
      registry = { ...registry, checked: true, error: error.message };
    }
  }

  if (options.installAdapters) {
    for (const provider of initialProviders) {
      if (registry.configured.includes(provider.id)) continue;
      if (!provider.agentInstalled || provider.adapterInstalled || !provider.install) continue;
      const args = provider.install.split(/\s+/).slice(1);
      actions.push({ type: "adapter", provider: provider.id, command: "npm", args });
      if (!options.dryRun) await requireSuccess(run, "npm", args, `install ${provider.id} ACP adapter`);
    }
  }

  const providers = options.installAdapters && !options.dryRun ? await detect() : initialProviders;
  const availableTargets = ["codex", "claude"].filter(
    (target) => providers.some((provider) => provider.id === target && provider.agentInstalled)
  );
  const requestedTargets = options.targets.length
    ? options.targets
    : availableTargets;
  const controlTargets = options.installControl
    ? (options.targets.length ? requestedTargets : [availableTargets.includes("codex") ? "codex" : availableTargets[0]].filter(Boolean))
    : [];
  const guideTargets = options.installGuide ? requestedTargets : [];
  const installedProviderIds = new Set([
    ...registry.configured,
    ...providers.filter((provider) => provider.agentInstalled).map((provider) => provider.id)
  ]);
  const skillTargets = options.installSkill
    ? (options.targets.length && !options.allTargets ? requestedTargets : [...installedProviderIds])
    : [];

  let identity = state?.identity ?? null;
  if ((options.installControl || options.installGuide || options.installSkill) && !state) {
    state = { version: 1, managedMcp: {}, managedSkills: {} };
  }
  if (options.installControl) {
    if (!identity || options.rotateToken) identity = createIdentity();
    state.identity = identity;
    state.managedMcp ??= {};
    state.updatedAt = new Date().toISOString();
    if (!options.dryRun) await writeInstallState(statePath, state);
  }

  const installedSkillDestinations = new Map();
  for (const target of new Set([...controlTargets, ...guideTargets, ...skillTargets])) {
    const provider = providers.find((item) => item.id === target);
    const needsMcp = controlTargets.includes(target) || guideTargets.includes(target);
    if (needsMcp && !provider?.agentInstalled) {
      warnings.push(`${target} is not installed; MCP registration skipped`);
    } else if (controlTargets.includes(target)) {
      const spec = mcpSpec(target, "control", identity);
      await installMcp(spec, { options, state, run, actions });
    }
    if (guideTargets.includes(target) && provider?.agentInstalled) {
      const spec = mcpSpec(target, "guide", identity);
      await installMcp(spec, { options, state, run, actions });
    }
    if (skillTargets.includes(target) && installedProviderIds.has(target)) {
      const destinationRoot = skillRoots[target] ?? skillRoots.default;
      if (!destinationRoot) throw new Error(`No skill installation path is configured for ${target}`);
      const destination = join(destinationRoot, DELEGATOR_SKILL_NAME);
      const sharedWith = installedSkillDestinations.get(destination);
      if (sharedWith) {
        actions.push({
          type: "skill",
          agent: target,
          name: DELEGATOR_SKILL_NAME,
          source: skillSource,
          destination,
          status: "shared",
          sharedWith
        });
        if (!options.dryRun) {
          state.managedSkills ??= {};
          state.managedSkills[`${target}:${DELEGATOR_SKILL_NAME}`] = {
            agent: target,
            name: DELEGATOR_SKILL_NAME,
            path: destination,
            sharedWith,
            installedAt: new Date().toISOString()
          };
        }
        continue;
      }
      installedSkillDestinations.set(destination, target);
      await installBundledSkill(target, {
        source: skillSource,
        destinationRoot,
        options,
        state,
        actions
      });
    } else if (skillTargets.includes(target)) {
      warnings.push(`${target} is not installed; skill installation skipped`);
    }
  }

  if (state && !options.dryRun && (options.installControl || options.installGuide || options.installSkill)) {
    state.updatedAt = new Date().toISOString();
    await writeInstallState(statePath, state);
  }

  let health = { checked: false };
  if (options.installControl && options.healthCheck && !options.dryRun) {
    const rpc = makeRpc({ token: identity.token, rootId: identity.rootId });
    try {
      const result = await rpc.call("session", { action: "list" }, 10_000);
      health = { checked: true, ok: result?.ok === true };
      if (!health.ok) throw new Error("Gateway health check returned an invalid response");
    } finally {
      rpc.close();
    }
  }

  return {
    ok: true,
    dryRun: options.dryRun,
    statePath,
    providers,
    targets: { control: controlTargets, guide: guideTargets, skill: skillTargets },
    actions,
    health,
    warnings,
    registry,
    identity: identity
      ? {
          rootId: identity.rootId,
          token: options.showSecrets ? identity.token : undefined,
          tokenStored: !options.dryRun,
          rotated: options.rotateToken
        }
      : undefined
  };
}

export function installerHelp() {
  return [
    "Usage: acp-gateway-bootstrap [options]",
    "",
    "  --install-all          Install adapters, Control, Guide, and agent-delegator",
    "  --install-adapters     Install missing ACP adapters",
    "  --discover-agents      Match installed AI CLIs with the official ACP registry",
    "  --registry-agent <id>  Install/configure one official registry agent (repeatable)",
    "  --refresh-registry     Refresh the cached official ACP registry",
    "  --offline              Use only the cached ACP registry",
    "  --install-control      Register the Main-only Control MCP",
    "  --install-guide        Register the read-only Guide MCP",
    "  --install-skill        Install agent-delegator for every discovered agent",
    "  --target <agent>       codex, claude, or all (repeatable)",
    "  --rotate-token         Rotate credentials and update Control MCP entries",
    "  --dry-run              Print planned changes without modifying the system",
    "  --force                Replace same-name MCP entries not managed by this installer",
    "  --skip-health-check    Do not start/connect to the daemon after installation",
    "  --show-secrets         Include the generated Control token in JSON output",
    "  --help                 Show this help"
  ].join("\n");
}

async function installMcp(spec, { options, state, run, actions }) {
  const key = `${spec.agent}:${spec.name}`;
  actions.push({ type: "mcp", agent: spec.agent, name: spec.name, command: spec.command, args: redactArgs(spec.args) });
  if (options.dryRun) return;

  const existing = await run(spec.command, spec.getArgs);
  const exists = existing.code === 0;
  if (!exists && !/no mcp server|not found|does not exist/i.test(`${existing.stdout}\n${existing.stderr}`)) {
    throw commandError(spec.command, spec.getArgs, existing, `inspect ${key}`);
  }
  if (exists && !state?.managedMcp?.[key] && !options.force) {
    throw new Error(`${key} already exists and is not managed by this installer; rerun with --force to replace it`);
  }
  if (exists && state?.managedMcp?.[key] && !options.force && !options.rotateToken) {
    actions.at(-1).status = "unchanged";
    return;
  }
  if (exists) await requireSuccess(run, spec.command, spec.removeArgs, `remove existing ${key}`);
  await requireSuccess(run, spec.command, spec.args, `install ${key}`);
  state.managedMcp ??= {};
  state.managedMcp[key] = { agent: spec.agent, name: spec.name, kind: spec.kind, installedAt: new Date().toISOString() };
}

async function installBundledSkill(agent, { source, destinationRoot, options, state, actions }) {
  if (!destinationRoot) throw new Error(`No skill installation path is configured for ${agent}`);
  const destination = join(destinationRoot, DELEGATOR_SKILL_NAME);
  const key = `${agent}:${DELEGATOR_SKILL_NAME}`;
  const exists = await pathExists(destination);
  actions.push({ type: "skill", agent, name: DELEGATOR_SKILL_NAME, source, destination });
  if (options.dryRun) return;
  const managedDestination = Object.values(state?.managedSkills ?? {}).some((item) => item?.path === destination);
  if (exists && !state?.managedSkills?.[key] && !managedDestination && !options.force) {
    throw new Error(`${key} already exists and is not managed by this installer; rerun with --force to replace it`);
  }

  await mkdir(destinationRoot, { recursive: true, mode: 0o700 });
  const suffix = `${process.pid}-${randomBytes(4).toString("hex")}`;
  const temporary = `${destination}.tmp-${suffix}`;
  const backup = `${destination}.backup-${suffix}`;
  await cp(source, temporary, { recursive: true, errorOnExist: true, force: false });
  let backedUp = false;
  try {
    if (exists) {
      await rename(destination, backup);
      backedUp = true;
    }
    await rename(temporary, destination);
    if (backedUp) await rm(backup, { recursive: true, force: true });
  } catch (error) {
    await rm(temporary, { recursive: true, force: true }).catch(() => {});
    if (backedUp && !(await pathExists(destination))) await rename(backup, destination).catch(() => {});
    throw error;
  }
  state.managedSkills ??= {};
  state.managedSkills[key] = { agent, name: DELEGATOR_SKILL_NAME, path: destination, installedAt: new Date().toISOString() };
}

function mcpSpec(agent, kind, identity) {
  const isControl = kind === "control";
  const name = isControl ? CONTROL_NAME : GUIDE_NAME;
  const script = join(sourceDirectory, isControl ? "index.js" : "guide.js");
  const serverCommand = stableNodeCommand();
  const serverArgs = [script];
  if (agent === "codex") {
    const envArgs = isControl
      ? ["--env", `ACP_GATEWAY_CONTROL_TOKEN=${identity.token}`, "--env", `ACP_GATEWAY_ROOT_ID=${identity.rootId}`]
      : [];
    return {
      agent, kind, name, command: "codex",
      getArgs: ["mcp", "get", name, "--json"],
      removeArgs: ["mcp", "remove", name],
      args: ["mcp", "add", ...envArgs, name, "--", serverCommand, ...serverArgs]
    };
  }
  const envArgs = isControl
    ? ["-e", `ACP_GATEWAY_CONTROL_TOKEN=${identity.token}`, "-e", `ACP_GATEWAY_ROOT_ID=${identity.rootId}`]
    : [];
  return {
    agent, kind, name, command: "claude",
    getArgs: ["mcp", "get", name],
    removeArgs: ["mcp", "remove", "--scope", "user", name],
    args: ["mcp", "add", "--scope", "user", ...envArgs, name, "--", serverCommand, ...serverArgs]
  };
}

function stableNodeCommand() {
  if (process.env.ACP_GATEWAY_NODE) return process.env.ACP_GATEWAY_NODE;
  for (const directory of (process.env.PATH ?? "").split(delimiter).filter(Boolean)) {
    const candidate = join(directory, "node");
    try {
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // Continue searching PATH for a stable launcher path.
    }
  }
  return process.execPath;
}

function createIdentity() {
  return {
    token: randomBytes(32).toString("base64url"),
    rootId: `main-${randomBytes(8).toString("hex")}`,
    createdAt: new Date().toISOString()
  };
}

async function readInstallState(path) {
  try {
    const state = JSON.parse(await readFile(path, "utf8"));
    if (state?.version !== 1 || typeof state.managedMcp !== "object") throw new Error("unsupported install state format");
    if (state.identity && (typeof state.identity.token !== "string" || state.identity.token.length < 24)) {
      throw new Error("invalid stored Control identity");
    }
    return state;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw new Error(`Cannot read installer state ${path}: ${error.message}`);
  }
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

async function writeInstallState(path, state) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
  await chmod(path, 0o600);
}

function preflight({ nodeVersion, platform }) {
  const major = Number(String(nodeVersion).split(".")[0]);
  if (!Number.isInteger(major) || major < 22) throw new Error(`Node.js 22 or newer is required; found ${nodeVersion}`);
  if (platform === "win32") throw new Error("The local Unix-socket Gateway installer currently supports macOS and Linux only");
}

async function requireSuccess(run, command, args, operation) {
  const result = await run(command, args);
  if (result.code !== 0) throw commandError(command, args, result, operation);
  return result;
}

function commandError(command, args, result, operation) {
  const detail = String(result.stderr || result.stdout || "unknown error").trim();
  return new Error(`${operation} failed (${command} ${redactArgs(args).join(" ")}): ${detail}`);
}

function redactArgs(args) {
  return args.map((arg) => String(arg).replace(/^(ACP_GATEWAY_CONTROL_TOKEN=).+$/, "$1<redacted>"));
}

export function runCommand(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}
