import {
  defaultProviderRegistryPath,
  discoverRegistryAgents,
  installedGlobalNpmPackages,
  loadOfficialRegistry,
  mergeProviderDefinitions,
  providerDefinition,
  providerIdForRegistryAgent,
  readProviderRegistry,
  selectDistribution,
  setProviderEnabled
} from "./acp-registry.js";
import { detectProviders } from "./providers.js";
import { spawn } from "node:child_process";

async function runCommand(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { env: process.env, stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code: code ?? 1, stdout, stderr }));
  });
}

export async function officialAgentCatalog({
  refresh = false,
  offline = false,
  registryLoader = loadOfficialRegistry,
  registryDiscover = discoverRegistryAgents,
  detect = detectProviders,
  run = runCommand,
  platform = process.platform,
  arch = process.arch,
  providerRegistryPath = defaultProviderRegistryPath()
} = {}) {
  const loaded = await registryLoader({ refresh, offline });
  const installedPackages = await installedGlobalNpmPackages(run);
  const [discovered, detected, providerRegistry] = await Promise.all([
    registryDiscover(loaded.registry, { installedPackages, platform, arch }),
    detect(),
    readProviderRegistry(providerRegistryPath)
  ]);
  const discoveredByRegistryId = new Map(discovered.map((item) => [item.registryId, item]));
  const detectedByRegistryId = new Map(detected.filter((item) => item.registryId).map((item) => [item.registryId, item]));
  const detectedByProviderId = new Map(detected.map((item) => [item.id, item]));
  const disabled = new Set(providerRegistry.disabled);

  const agents = loaded.registry.agents.map((agent) => {
    const providerId = providerIdForRegistryAgent(agent.id);
    const distribution = selectDistribution(agent, platformTarget(platform, arch));
    const localMatch = discoveredByRegistryId.get(agent.id);
    const detectedProvider = detectedByRegistryId.get(agent.id) ?? detectedByProviderId.get(providerId);
    const installed = Boolean(
      detectedProvider
      && detectedProvider.agentInstalled
      && detectedProvider.adapterInstalled
    );
    const enabled = installed && !disabled.has(providerId) && detectedProvider?.enabled !== false;
    const installSupported = Boolean(distribution && (distribution.type !== "binary" || localMatch));
    return {
      registryId: agent.id,
      providerId,
      name: agent.name,
      version: agent.version,
      // What the ACP registry currently offers (`version`) vs what this Mac has
      // configured (`installedVersion`, from providers.json). The app compares
      // the two to offer an adapter update; null when nothing is installed.
      installedVersion: installed ? (detectedProvider?.registryVersion ?? null) : null,
      description: typeof agent.description === "string" ? agent.description : "",
      website: firstWebUrl(agent.website, agent.repository),
      icon: firstWebUrl(agent.icon),
      distribution: distribution?.type ?? "unsupported",
      compatible: Boolean(distribution),
      installed,
      enabled,
      installSupported,
      installHint: installSupported
        ? (localMatch && distribution?.type === "binary" ? "로컬 binary를 ACP Gateway에 연결합니다." : "공식 registry 배포본을 설치합니다.")
        : distribution?.type === "binary"
          ? "공식 binary를 먼저 설치해야 합니다."
          : "이 Mac을 지원하는 배포본이 없습니다."
    };
  }).sort((left, right) => left.name.localeCompare(right.name));

  return {
    ok: true,
    registryVersion: loaded.registry.version,
    source: loaded.source,
    stale: loaded.stale,
    warning: loaded.warning ?? null,
    agents
  };
}

export async function installOfficialAgent(registryId, {
  providerRegistryPath = defaultProviderRegistryPath(),
  registryLoader = loadOfficialRegistry,
  registryDiscover = discoverRegistryAgents,
  run = runCommand,
  platform = process.platform,
  arch = process.arch
} = {}) {
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(registryId)) throw new Error(`invalid registry agent id: ${registryId}`);
  const loaded = await registryLoader({ refresh: true });
  const agent = loaded.registry.agents.find((item) => item.id === registryId);
  if (!agent) throw new Error(`Official ACP agent not found: ${registryId}`);
  const installedPackages = await installedGlobalNpmPackages(run);
  const discovered = await registryDiscover(loaded.registry, { installedPackages, platform, arch });
  let match = discovered.find((item) => item.registryId === registryId);
  if (!match) {
    const distribution = selectDistribution(agent, platformTarget(platform, arch));
    if (!distribution) throw new Error(`${registryId} has no distribution for this platform`);
    if (distribution.type === "binary") throw new Error(`${registryId} must be installed from its official binary first`);
    match = {
      id: providerIdForRegistryAgent(agent.id),
      registryId: agent.id,
      name: agent.name,
      version: agent.version,
      distribution,
      foundCommand: null,
      packageInstalled: false
    };
  }
  if (["npx", "uvx"].includes(match.distribution.type)) {
    const command = match.distribution.type === "npx" ? "npm" : "uv";
    const args = match.distribution.type === "npx"
      ? ["install", "--global", match.distribution.package]
      : ["tool", "install", "--force", match.distribution.package];
    const result = await run(command, args);
    if (result.code !== 0) throw new Error(`Failed to install ${registryId}: ${result.stderr || result.stdout}`);
  }
  const definition = providerDefinition(match);
  await mergeProviderDefinitions(providerRegistryPath, [definition]);
  const providerId = providerIdForRegistryAgent(registryId);
  await setProviderEnabled(providerId, true, providerRegistryPath);
  return { ok: true, providerId };
}

export async function setOfficialAgentEnabled(providerId, enabled, {
  providerRegistryPath = defaultProviderRegistryPath()
} = {}) {
  await setProviderEnabled(providerId, enabled, providerRegistryPath);
  return { ok: true, providerId, enabled };
}

function firstWebUrl(...values) {
  for (const value of values) {
    if (typeof value !== "string") continue;
    try {
      const url = new URL(value);
      if (["https:", "http:"].includes(url.protocol)) return url.href;
    } catch {
      // Ignore malformed optional registry metadata.
    }
  }
  return null;
}

function platformTarget(platform, arch) {
  const platformName = platform === "darwin" ? "darwin" : platform === "linux" ? "linux" : platform === "win32" ? "windows" : platform;
  const archName = arch === "arm64" ? "aarch64" : arch === "x64" ? "x86_64" : arch;
  return `${platformName}-${archName}`;
}
