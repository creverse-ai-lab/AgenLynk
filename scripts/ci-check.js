#!/usr/bin/env node

import assert from "node:assert/strict";
import { access, readFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { readGatewayLock } from "./fetch-gateway-runtime.js";
import { collectSidecarPrivateImportViolations } from "./sidecar-private-imports.js";
import { SIDECAR_BUILD_ID, SIDECAR_VERSION } from "../sidecar/src/version.js";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const packageDocument = JSON.parse(await readFile(join(root, "package.json"), "utf8"));
const sidecarPackage = JSON.parse(await readFile(join(root, "sidecar/package.json"), "utf8"));
const lock = await readGatewayLock(join(root, "gateway.lock.json"));

assert.equal(packageDocument.name, "agenlynk");
assert.equal(packageDocument.version, "0.4.0");
assert.equal(packageDocument.dependencies, undefined, "root package must not carry Gateway dependencies");
assert.deepEqual(Object.keys(packageDocument.bin), ["agenlynk-sidecar"]);
assert.equal(sidecarPackage.version, SIDECAR_VERSION);
assert.match(SIDECAR_BUILD_ID, /^[a-f0-9]{16}$/);
assert.equal(lock.version, "1.4.0");
assert.equal(lock.apiMajor, 1);

const allowedRuntimeFiles = new Set([
  "build-release-manifest-cli.js",
  "build-runtime-manifest-cli.js",
  "runtime-installer-cli.js",
  "runtime-installer.js",
  "runtime-lock.js",
  "runtime-manifest.js",
  "runtime-pointer.js",
  "runtime-smoke-check.js",
  "runtime-staging.js",
  "runtime-updater-cli.js",
  "runtime-updater.js",
  "verify-runtime-manifest-cli.js"
]);
assert.deepEqual(new Set(await readdir(join(root, "src"))), allowedRuntimeFiles, "src/ must contain app runtime integration only");

for (const forbidden of [
  "skills/agent-delegator/SKILL.md",
  "config/acp-monitor.json",
  ".github/workflows/acp-upstream-monitor.yml",
  "sidecar/src/gateway/legacy-adapter.js"
]) {
  await assert.rejects(access(join(root, forbidden)), undefined, `${forbidden} must be removed`);
}

const violations = await collectSidecarPrivateImportViolations(join(root, "sidecar/src"));
assert.deepEqual(violations, [], violations.map((item) => `${item.path}: ${item.patterns.join(",")}`).join("; "));

const monitorSource = await readFile(join(root, "sidecar/src/server/monitor.js"), "utf8");
assert.doesNotMatch(monitorSource, /\.call\(["'](?:gateway_config|retention_preview)["']/, "sidecar must not probe undeclared Gateway RPC methods");
assert.doesNotMatch(monitorSource, /(?:error|message)[^\n]*\.includes\(/, "Gateway compatibility must not branch on message substrings");
assert.doesNotMatch(monitorSource, /\blet gatewaySessions\b/, "MonitorState must own the Gateway session source");

process.stdout.write("AgenLynk ownership and pinned Gateway boundary checks passed\n");
