import {
  defaultProviderRegistryPath,
  discoverRegistryAgents,
  installedGlobalNpmPackages,
  loadOfficialRegistry,
  providerIdForRegistryAgent,
  readProviderRegistry,
  selectDistribution,
  setProviderEnabled
} from "./acp-registry.js";
import { parseInstallerArgs, runCommand, runInstaller } from "./installer.js";
import { detectProviders } from "./providers.js";

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
  installer = runInstaller,
  installerDependencies = {}
} = {}) {
  if (!/^[a-z0-9][a-z0-9._-]*$/.test(registryId)) throw new Error(`invalid registry agent id: ${registryId}`);
  const options = parseInstallerArgs(["--registry-agent", registryId, "--skip-health-check"]);
  // The general CLI intentionally discovers all installed agents. A row-level UI
  // action must configure only the agent the user selected.
  options.registryAgentsOnly = true;
  const result = await installer(options, { ...installerDependencies, providerRegistryPath });
  const providerId = providerIdForRegistryAgent(registryId);
  await setProviderEnabled(providerId, true, providerRegistryPath);
  return { ok: true, providerId, result };
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
