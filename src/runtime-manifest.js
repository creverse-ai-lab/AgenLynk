// Manifest for a Gateway runtime seed/installation: the same shape is used
// by the DMG build (to snapshot what it shipped) and by runtime-installer.js
// (to reject an incomplete/corrupt copy before it is activated). Reuses
// src/version.js's existing GATEWAY_VERSION/GATEWAY_BUILD_ID rather than
// inventing a separate identifier or hashing scheme: gatewayBuildId is
// re-derived by dynamically importing the *copied* version.js, so a
// corrupted or truncated src/**/*.js, package.json, or package-lock.json at
// that root produces a different id and fails verification.
import { execFile } from "node:child_process";
import { access, readFile } from "node:fs/promises";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const RUNTIME_MANIFEST_FORMAT_VERSION = 1;

// Marker files whose presence (not full content) is checked directly,
// without spawning Node or importing anything. Kept short and cheap: this is
// an incomplete-copy guard, not a full integrity scan of node_modules.
export const REQUIRED_RUNTIME_FILES = [
  "package.json",
  "package-lock.json",
  "src/index.js",
  "src/guide.js",
  "src/bootstrap.js",
  "src/monitor.js",
  "src/version.js",
  "src/installer.js",
  "skills/agent-delegator/SKILL.md",
  "node_modules/@agentclientprotocol/claude-agent-acp/package.json",
  "node_modules/@modelcontextprotocol/sdk/package.json",
  "node/bin/node",
  "node/bin/npm",
  "node/bin/npx"
];

export async function assertRequiredFilesExist(root, files = REQUIRED_RUNTIME_FILES) {
  for (const relative of files) {
    try {
      await access(join(root, relative));
    } catch {
      throw new Error(`runtime is missing a required file: ${relative}`);
    }
  }
}

/** Imports `<root>/src/version.js` so GATEWAY_BUILD_ID reflects that root's actual files. */
export async function readGatewayIdentity(root) {
  const versionModuleURL = pathToFileURL(join(root, "src", "version.js")).href;
  const module = await import(versionModuleURL);
  if (typeof module.GATEWAY_VERSION !== "string" || typeof module.GATEWAY_BUILD_ID !== "string") {
    throw new Error(`${root}/src/version.js did not export GATEWAY_VERSION/GATEWAY_BUILD_ID`);
  }
  return { gatewayVersion: module.GATEWAY_VERSION, gatewayBuildId: module.GATEWAY_BUILD_ID };
}

async function readExecutableVersion(binaryPath, args = ["--version"]) {
  const { stdout } = await execFileAsync(binaryPath, args);
  return stdout.trim().replace(/^v/, "");
}

export async function buildRuntimeManifest(root, { nodeVersion } = {}) {
  await assertRequiredFilesExist(root);
  const identity = await readGatewayIdentity(root);
  const resolvedNodeVersion = nodeVersion ?? await readExecutableVersion(join(root, "node/bin/node"));
  return {
    formatVersion: RUNTIME_MANIFEST_FORMAT_VERSION,
    gatewayVersion: identity.gatewayVersion,
    gatewayBuildId: identity.gatewayBuildId,
    nodeVersion: resolvedNodeVersion,
    requiredFiles: REQUIRED_RUNTIME_FILES,
    generatedAt: new Date().toISOString()
  };
}

/**
 * Re-derives a root's identity/executables and throws with an actionable
 * message on the first mismatch. Used both right after staging a copy
 * (reject before activating) and as a fast idempotency check on every
 * startup (skip re-copying an already-valid installed version).
 */
export async function verifyRuntimeManifest(root, manifest) {
  if (!manifest || manifest.formatVersion !== RUNTIME_MANIFEST_FORMAT_VERSION) {
    throw new Error("unsupported runtime manifest format");
  }
  await assertRequiredFilesExist(root, manifest.requiredFiles ?? REQUIRED_RUNTIME_FILES);

  const identity = await readGatewayIdentity(root);
  if (identity.gatewayVersion !== manifest.gatewayVersion || identity.gatewayBuildId !== manifest.gatewayBuildId) {
    throw new Error(
      `runtime content does not match its manifest (expected ${manifest.gatewayVersion}/${manifest.gatewayBuildId}, found ${identity.gatewayVersion}/${identity.gatewayBuildId})`
    );
  }

  const nodeVersion = await readExecutableVersion(join(root, "node/bin/node"));
  if (manifest.nodeVersion && nodeVersion !== manifest.nodeVersion) {
    throw new Error(`installed Node version mismatch (expected ${manifest.nodeVersion}, found ${nodeVersion})`);
  }
  // npm/npx must actually execute (not just exist) so a corrupted symlink/shim
  // is rejected the same way a corrupted node binary would be.
  await readExecutableVersion(join(root, "node/bin/npm"));
  await readExecutableVersion(join(root, "node/bin/npx"));

  return identity;
}

export async function readManifestFile(root) {
  return JSON.parse(await readFile(join(root, "runtime-manifest.json"), "utf8"));
}
