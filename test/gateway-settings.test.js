import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  GATEWAY_SETTING_DEFINITIONS,
  gatewaySettingsSnapshot,
  resolveGatewaySettings,
  updateGatewaySettings
} from "../src/gateway-settings.js";

test("Gateway settings expose every safe runtime option without secrets", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-gateway-settings-"));
  const statePath = join(directory, "install.json");
  const token = "test-control-token-at-least-24-characters";
  try {
    await writeFile(statePath, JSON.stringify({
      version: 1,
      managedMcp: {},
      identity: { token, rootId: "main-test" },
      agentUpdates: { autoUpdate: true, notifications: true }
    }));
    const snapshot = gatewaySettingsSnapshot({ statePath, env: {} });
    assert.equal(snapshot.options.length, 24);
    assert.equal(snapshot.options.length, GATEWAY_SETTING_DEFINITIONS.length);
    assert.equal(snapshot.options.find((item) => item.id === "maxInlineResultBytes").currentValue, 65_536);
    // Workers stay thought-visible unless an operator turns it off: the adapter
    // emits no reasoning at all until the Gateway asks for it.
    assert.equal(snapshot.options.find((item) => item.id === "workerThoughtStream").currentValue, true);
    assert.equal(JSON.stringify(snapshot).includes(token), false);
    assert.equal(snapshot.pendingRestart, false);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Gateway settings persist atomically, preserve install identity, and reset to defaults", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-gateway-settings-persist-"));
  const statePath = join(directory, "install.json");
  const token = "test-control-token-at-least-24-characters";
  try {
    await writeFile(statePath, JSON.stringify({
      version: 1,
      managedMcp: { "codex:agent-acp": { agent: "codex" } },
      identity: { token, rootId: "main-test" },
      agentUpdates: { autoUpdate: true, notifications: true }
    }), { mode: 0o600 });
    await updateGatewaySettings({
      statePath,
      env: {},
      values: {
        gcIntervalMs: 9_000,
        maxEvents: 400,
        maxInlineResultBytes: 32_768,
        workerThoughtStream: false,
        localScanIntervalMs: 2_000,
        localTranscriptRecordLimit: 1_000,
        agentAutoUpdate: false,
        agentUpdateIntervalMs: 600_000
      }
    });
    const saved = JSON.parse(await readFile(statePath, "utf8"));
    assert.equal(saved.identity.token, token);
    assert.equal(saved.managedMcp["codex:agent-acp"].agent, "codex");
    assert.equal(saved.gatewayConfig.lifecycle.gcIntervalMs, 9_000);
    assert.equal(saved.gatewayConfig.resourceLimits.maxEvents, 400);
    assert.equal(saved.gatewayConfig.workers.workerThoughtStream, false);
    assert.equal(saved.gatewayConfig.monitor.localScanIntervalMs, 2_000);
    assert.equal(saved.agentUpdates.autoUpdate, false);
    assert.equal(saved.agentUpdates.intervalMs, 600_000);
    assert.equal((await stat(statePath)).mode & 0o777, 0o600);
    const resolved = resolveGatewaySettings({ statePath, env: {} });
    assert.equal(resolved.maxInlineResultBytes, 32_768);
    assert.equal(resolved.localTranscriptRecordLimit, 1_000);

    await updateGatewaySettings({ statePath, env: {}, resetIds: ["gcIntervalMs", "agentAutoUpdate"] });
    const reset = resolveGatewaySettings({ statePath, env: {} });
    assert.equal(reset.gcIntervalMs, 300_000);
    assert.equal(reset.agentAutoUpdate, true);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Gateway settings validate values and lock environment overrides", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-gateway-settings-validation-"));
  const statePath = join(directory, "install.json");
  try {
    await writeFile(statePath, JSON.stringify({ version: 1, managedMcp: {}, agentUpdates: { autoUpdate: true, notifications: true } }));
    const env = { ACP_GATEWAY_MAX_EVENTS: "321" };
    const snapshot = gatewaySettingsSnapshot({ statePath, env });
    const option = snapshot.options.find((item) => item.id === "maxEvents");
    assert.equal(option.currentValue, 321);
    assert.equal(option.source, "environment");
    assert.equal(option.editable, false);
    await assert.rejects(
      updateGatewaySettings({ statePath, env, values: { maxEvents: 500 } }),
      /locked by ACP_GATEWAY_MAX_EVENTS/
    );
    await assert.rejects(updateGatewaySettings({ statePath, env: {}, values: { maxEvents: 0 } }), /integer >= 1/);
    await assert.rejects(updateGatewaySettings({ statePath, env: {}, values: { mystery: 1 } }), /Unknown Gateway config option/);
    await assert.rejects(
      updateGatewaySettings({ statePath, env: {}, values: { maxArtifactBytes: 1000, maxArtifactTotalBytes: 999 } }),
      /greater than or equal/
    );
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});

test("Gateway settings cannot create an install state before bootstrap", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-gateway-settings-uninstalled-"));
  const statePath = join(directory, "install.json");
  try {
    await assert.rejects(
      updateGatewaySettings({ statePath, env: {}, values: { maxEvents: 300 } }),
      /must be installed/
    );
    await assert.rejects(readFile(statePath, "utf8"), { code: "ENOENT" });
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
