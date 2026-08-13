#!/usr/bin/env node

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { collectSidecarPrivateImportViolations } from "./sidecar-private-imports.js";
import { parseInstallerArgs } from "../src/installer.js";
import { GATEWAY_BUILD_ID, GATEWAY_VERSION } from "../src/version.js";
import { ACP_PROTOCOL_VERSION } from "../src/acp-version.js";
import { SIDECAR_BUILD_ID, SIDECAR_VERSION } from "../sidecar/src/version.js";
import { compareSnapshots, validateMonitorConfig, validateSnapshot } from "./acp-upstream-monitor.js";

const packageDocument = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
const sidecarPackage = JSON.parse(await readFile(new URL("../sidecar/package.json", import.meta.url), "utf8"));
const monitorConfig = JSON.parse(await readFile(new URL("../config/acp-monitor.json", import.meta.url), "utf8"));
const upstreamSnapshot = JSON.parse(await readFile(new URL("../config/acp-upstream.snapshot.json", import.meta.url), "utf8"));

assert.equal(packageDocument.version, GATEWAY_VERSION, "package and Gateway versions must match");
assert.match(GATEWAY_BUILD_ID, /^[a-f0-9]{16}$/, "Gateway build id must be a short source fingerprint");
assert.equal(sidecarPackage.version, SIDECAR_VERSION, "sidecar package and runtime versions must match");
assert.match(SIDECAR_BUILD_ID, /^[a-f0-9]{16}$/, "sidecar build id must be a short source fingerprint");
await assertSidecarPrivateImportsAreIsolated();
validateMonitorConfig(monitorConfig);
validateSnapshot(upstreamSnapshot, monitorConfig);
assert.deepEqual(
  monitorConfig.supportedWireVersions,
  [ACP_PROTOCOL_VERSION],
  "runtime ACP protocol version and monitor config must match"
);
for (const [agentId, packageName] of Object.entries(monitorConfig.managedNpmAdapters)) {
  const upstreamVersion = upstreamSnapshot.registry.agents[agentId]?.version;
  assert.equal(
    packageDocument.dependencies?.[packageName],
    upstreamVersion,
    `${packageName} must match the monitored ${agentId} version`
  );
}

const reorderedSnapshot = structuredClone(upstreamSnapshot);
const sampleAgent = monitorConfig.watchedAgents[0];
const sampleDistribution = reorderedSnapshot.registry.agents[sampleAgent].distribution;
reorderedSnapshot.registry.agents[sampleAgent].distribution = Object.fromEntries(
  Object.entries(sampleDistribution).reverse()
);
assert.deepEqual(
  compareSnapshots(upstreamSnapshot, reorderedSnapshot, monitorConfig),
  [],
  "distribution object key order must not create a false upstream change"
);

const install = parseInstallerArgs(["--install-all"]);
assert.equal(install.installSkill, true, "first install must include the delegation skill");
const update = parseInstallerArgs(["--update"]);
assert.equal(update.installSkill, false, "updates must preserve customized skills");
assert.equal(update.restartDaemon, true, "updates must restart the daemon");
const skillUpdate = parseInstallerArgs(["--update-skill"]);
assert.equal(skillUpdate.updateSkill, true, "skill updates must use the managed-copy update path");
assert.equal(skillUpdate.update, false, "skill updates must not pull or update runtime components");
assert.equal(skillUpdate.restartDaemon, false, "skill-only updates must not restart the daemon");

process.stdout.write("ACP Gateway CI checks passed\n");

async function assertSidecarPrivateImportsAreIsolated() {
  const sourceRoot = fileURLToPath(new URL("../sidecar/src/", import.meta.url));
  const violations = await collectSidecarPrivateImportViolations(sourceRoot);
  assert.deepEqual(
    violations,
    [],
    violations.map((item) => `${item.path}: ${item.patterns.join(",")}`).join("; ")
      || "sidecar private imports must stay inside gateway/legacy-adapter.js"
  );
}
