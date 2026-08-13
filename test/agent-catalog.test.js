import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { installOfficialAgent, officialAgentCatalog } from "../sidecar/src/app/agent-catalog.js";
import { mergeProviderDefinitions, readProviderRegistry, setProviderEnabled } from "../sidecar/src/app/acp-registry.js";

const registry = {
  version: "1.0.0",
  agents: [
    { id: "claude-acp", name: "Claude", version: "1", distribution: { npx: { package: "claude-acp@1" } } },
    { id: "gemini", name: "Gemini", version: "2", distribution: { npx: { package: "gemini@2" } } },
    { id: "cursor", name: "Cursor", version: "3", distribution: { binary: { "darwin-aarch64": { archive: "https://example.test/cursor.tgz", cmd: "./cursor-agent" } } } },
    { id: "manual", name: "Manual", version: "4", distribution: { binary: { "darwin-aarch64": { archive: "https://example.test/manual.tgz", cmd: "./manual" } } } }
  ]
};

test("official agent catalog separates installed, enabled, and install-supported state", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-agent-catalog-"));
  const providerRegistryPath = join(directory, "providers.json");
  try {
    await mergeProviderDefinitions(providerRegistryPath, [{ id: "gemini", command: "npx", args: ["gemini"], env: {} }]);
    await setProviderEnabled("gemini", false, providerRegistryPath);
    const snapshot = await officialAgentCatalog({
      registryLoader: async () => ({ registry, source: "cache", stale: false }),
      registryDiscover: async () => [{ registryId: "cursor" }],
      detect: async () => [
        { id: "claude", agentInstalled: true, adapterInstalled: true, enabled: true },
        { id: "gemini", registryId: "gemini", agentInstalled: true, adapterInstalled: true, enabled: false }
      ],
      run: async () => ({ code: 0, stdout: '{"dependencies":{}}', stderr: "" }),
      platform: "darwin",
      arch: "arm64",
      providerRegistryPath
    });
    const byId = Object.fromEntries(snapshot.agents.map((agent) => [agent.registryId, agent]));
    assert.equal(byId["claude-acp"].installed, true);
    assert.equal(byId["claude-acp"].enabled, true);
    assert.equal(byId.gemini.installed, true);
    assert.equal(byId.gemini.enabled, false);
    assert.equal(byId.cursor.installed, false);
    assert.equal(byId.cursor.installSupported, true);
    assert.equal(byId.manual.installSupported, false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("row-level official agent install downloads only the selected registry distribution and enables it", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-agent-install-"));
  const providerRegistryPath = join(directory, "providers.json");
  const commands = [];
  try {
    await mergeProviderDefinitions(providerRegistryPath, [{ id: "gemini", command: "npx", args: ["gemini"], env: {} }]);
    await setProviderEnabled("gemini", false, providerRegistryPath);
    await installOfficialAgent("gemini", {
      providerRegistryPath,
      registryLoader: async () => ({ registry, source: "network", stale: false }),
      registryDiscover: async () => [],
      run: async (command, args) => {
        commands.push([command, args]);
        return command === "npm" && args[0] === "list"
          ? { code: 0, stdout: '{"dependencies":{}}', stderr: "" }
          : { code: 0, stdout: "", stderr: "" };
      }
    });
    assert.deepEqual(commands.at(-1), ["npm", ["install", "--global", "gemini@2"]]);
    const document = await readProviderRegistry(providerRegistryPath);
    assert.deepEqual(document.disabled, []);
    assert.equal(document.providers.gemini.registryId, "gemini");
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
