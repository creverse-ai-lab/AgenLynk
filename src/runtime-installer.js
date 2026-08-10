// Copies the app bundle's runtime seed into a single, version-pinned install
// path (~/.acp-gateway/runtime/versions/<gatewayVersion>-<gatewayBuildId>/)
// and atomically activates it via current.json. This is the only place a
// packaged Lynk build's Node/monitor/bootstrap should ever run from — the
// app bundle itself is seed input only (see TODO.md's fixed runtime
// boundary). install.json (Control identity/state) is never touched here;
// existing installs keep their identity untouched.
import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, relative, sep } from "node:path";
import { readManifestFile, verifyRuntimeManifest } from "./runtime-manifest.js";
import { CURRENT_POINTER_FILE, readPointerFile, writePointerFile } from "./runtime-pointer.js";
import { stageVerifiedRuntime } from "./runtime-staging.js";
import { withRuntimeLock } from "./runtime-lock.js";

export function defaultRuntimeRoot() {
  return process.env.ACP_GATEWAY_RUNTIME_ROOT || join(homedir(), ".acp-gateway", "runtime");
}

/**
 * Idempotent: if the versioned target already exists and passes manifest
 * verification, this only (re)writes current.json — no re-copy. Otherwise it
 * stages a full copy under runtime/staging/<tmp>/, verifies it, and only
 * then renames it into versions/<id>/ (atomic on the same volume) before
 * activating current.json.
 *
 * Existing-runtime authority: if `current.json` already points at a
 * manifest-verified install inside this runtimeRoot's versions/ directory,
 * that install is returned as-is — the seed is never read, copied, or
 * activated. This is what lets an already-installed Gateway survive a Lynk
 * app update: a newer/older seed bundled with the app must not silently
 * displace a different, still-valid, already-current runtime. The seed is
 * only consulted (and current.json only repointed) when current is absent,
 * malformed, outside the managed versions root, or fails its own manifest
 * verification.
 */
export async function ensureRuntimeInstalled({ seedRoot, runtimeRoot = defaultRuntimeRoot() }) {
  const existing = await currentRuntimeIfValid(runtimeRoot);
  if (existing) return existing;

  // Same advisory lock as the updater's mutations: the provisioner runs on
  // every app launch and can otherwise interleave its rm/rename staging with
  // a user-driven stage/activate over the same versions/ tree.
  return withRuntimeLock(runtimeRoot, async () => {
    // Re-check under the lock: whoever held it may have just installed.
    const installed = await currentRuntimeIfValid(runtimeRoot);
    if (installed) return installed;

    const manifest = await readManifestFile(seedRoot);
    const versionDir = `${manifest.gatewayVersion}-${manifest.gatewayBuildId}`;
    const target = join(runtimeRoot, "versions", versionDir);

    if (!(await isValid(target, manifest))) {
      await stageAndActivate(seedRoot, runtimeRoot, target, manifest);
    }
    await activateCurrent(runtimeRoot, target, manifest);
    return { runtimeRoot: target, gatewayVersion: manifest.gatewayVersion, gatewayBuildId: manifest.gatewayBuildId };
  });
}

async function currentRuntimeIfValid(runtimeRoot) {
  try {
    // readCurrentRuntime only swallows ENOENT (nothing installed yet); a
    // malformed current.json (bad JSON, wrong shape) throws, and is treated
    // here the same as "absent" so it falls through to seed repair below
    // instead of crashing the caller.
    const current = await readCurrentRuntime(runtimeRoot);
    if (!current || !(await isConfinedToVersions(runtimeRoot, current.runtimeRoot))) return null;
    const ownManifest = await readManifestFile(current.runtimeRoot);
    if (ownManifest.gatewayVersion !== current.gatewayVersion || ownManifest.gatewayBuildId !== current.gatewayBuildId) {
      return null;
    }
    await verifyRuntimeManifest(current.runtimeRoot, ownManifest);
    return { runtimeRoot: current.runtimeRoot, gatewayVersion: current.gatewayVersion, gatewayBuildId: current.gatewayBuildId };
  } catch {
    return null;
  }
}

/**
 * Rejects anything not strictly inside `<runtimeRoot>/versions/` — both
 * lexically (plain `..` traversal in a tampered current.json) and, after
 * resolving symlinks, by real path (a candidate that lexically sits under
 * versions/ but is, or is reached through, a symlink pointing elsewhere).
 * Lexical confinement alone is not enough: a symlink anywhere in the
 * candidate's path can make it resolve outside versions/ while still
 * *looking* like it's inside.
 */
export async function isConfinedToVersions(runtimeRoot, candidate) {
  if (typeof candidate !== "string" || !candidate) return false;
  const versionsRoot = join(runtimeRoot, "versions");
  if (!isRelativelyConfined(versionsRoot, candidate)) return false;
  try {
    const [realVersionsRoot, realCandidate] = await Promise.all([realpath(versionsRoot), realpath(candidate)]);
    return isRelativelyConfined(realVersionsRoot, realCandidate);
  } catch {
    return false;
  }
}

function isRelativelyConfined(root, candidate) {
  const relativePath = relative(root, candidate);
  return relativePath !== "" && relativePath !== ".." && !relativePath.startsWith(`..${sep}`) && !isAbsolute(relativePath);
}

async function isValid(root, manifest) {
  try {
    await verifyRuntimeManifest(root, manifest);
    return true;
  } catch {
    return false;
  }
}

async function stageAndActivate(seedRoot, runtimeRoot, target, manifest) {
  await stageVerifiedRuntime({
    seedRoot,
    runtimeRoot,
    target,
    manifest,
    isConfined: isConfinedToVersions,
    onFailure: (error) => new Error(`runtime seed failed validation, install aborted: ${error.message}`),
    onConfinementViolation: () => new Error("staged runtime resolved outside the managed versions root, install aborted")
  });
}

export async function activateCurrent(runtimeRoot, target, manifest) {
  const payload = {
    formatVersion: 1,
    runtimeRoot: target,
    gatewayVersion: manifest.gatewayVersion,
    gatewayBuildId: manifest.gatewayBuildId,
    activatedAt: new Date().toISOString()
  };
  await writePointerFile(runtimeRoot, CURRENT_POINTER_FILE, payload);
  return payload;
}

export async function readCurrentRuntime(runtimeRoot = defaultRuntimeRoot()) {
  return readPointerFile(runtimeRoot, CURRENT_POINTER_FILE);
}
