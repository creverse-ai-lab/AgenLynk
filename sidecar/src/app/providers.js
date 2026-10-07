import { homedir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";
import { defaultProviderRegistryPath, executableExists } from "./acp-registry.js";

const GROK_BIN = process.env.GROK_BIN || join(homedir(), ".grok/bin/grok");

export const PROVIDERS = ["grok", "claude", "codex"];

export const PROVIDER_MANIFESTS = {
  grok: {
    id: "grok",
    displayName: "Grok",
    agentCommand: GROK_BIN,
    adapter: "built-in",
    install: null
  },
  claude: {
    id: "claude",
    displayName: "Claude Code",
    agentCommand: process.env.CLAUDE_CODE_EXECUTABLE || join(homedir(), ".local/bin/claude"),
    adapter: "@agentclientprotocol/claude-agent-acp",
    install: "npm install -g @agentclientprotocol/claude-agent-acp"
  },
  codex: {
    id: "codex",
    displayName: "Codex CLI",
    agentCommand: process.env.CODEX_PATH || "codex",
    adapter: process.env.CODEX_ACP_BIN || "codex-acp",
    install: "npm install -g @agentclientprotocol/codex-acp"
  }
};

export async function detectProviders() {
  const document = providerRegistryDocument();
  const builtins = await Promise.all(
    Object.values(PROVIDER_MANIFESTS).map(async (manifest) => ({
      ...manifest,
      enabled: !document.disabled.has(manifest.id),
      agentInstalled: await executableExists(manifest.agentCommand),
      adapterInstalled:
        manifest.adapter === "built-in" || manifest.id === "claude"
          ? true
          : await executableExists(manifest.adapter)
    }))
  );
  const dynamic = await Promise.all(Object.values(document.providers).map(async (definition) => ({
    id: definition.id,
    displayName: definition.displayName ?? definition.id,
    agentCommand: definition.command,
    adapter: definition.registryId ?? "registry",
    install: null,
    registryId: definition.registryId,
    registryVersion: definition.registryVersion,
    enabled: !document.disabled.has(definition.id),
    agentInstalled: await executableExists(definition.command),
    adapterInstalled: await executableExists(definition.command)
  })));
  const configuredById = new Map(dynamic.map((item) => [item.id, item]));
  return [
    ...builtins.map((item) => {
      const configured = configuredById.get(item.id);
      return configured
        ? {
            ...item,
            adapter: configured.adapter,
            adapterInstalled: configured.adapterInstalled,
            registryId: configured.registryId,
            registryVersion: configured.registryVersion
          }
        : item;
    }),
    ...dynamic.filter((item) => !PROVIDERS.includes(item.id))
  ];
}

function providerRegistryDocument() {
  if (process.env.ACP_GATEWAY_DISABLE_DYNAMIC_PROVIDERS === "1" && !process.env.ACP_GATEWAY_PROVIDERS) {
    return { providers: {}, disabled: new Set() };
  }
  const path = defaultProviderRegistryPath();
  try {
    const document = JSON.parse(readFileSync(path, "utf8"));
    if (document?.version !== 1 || !document.providers || typeof document.providers !== "object") {
      return { providers: {}, disabled: new Set() };
    }
    const result = {};
    for (const [id, value] of Object.entries(document.providers)) {
      if (!/^[a-z0-9][a-z0-9._-]*$/.test(id) || !value || typeof value !== "object") continue;
      if (typeof value.command !== "string" || !value.command || !Array.isArray(value.args) || value.args.some((item) => typeof item !== "string")) continue;
      if (value.env != null && (typeof value.env !== "object" || Array.isArray(value.env) || Object.values(value.env).some((item) => typeof item !== "string"))) continue;
      result[id] = { ...value, id, args: [...value.args], env: { ...(value.env ?? {}) } };
    }
    const disabled = new Set(Array.isArray(document.disabled)
      ? document.disabled.filter((id) => typeof id === "string")
      : []);
    return { providers: result, disabled };
  } catch {
    return { providers: {}, disabled: new Set() };
  }
}

