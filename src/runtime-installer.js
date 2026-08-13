// Copies the app bundle's runtime seed into a single, version-pinned install
// path (~/.acp-gateway/runtime/versions/<gatewayVersion>-<gatewayBuildId>-<sidecarBuildId>/)
// and atomically activates it via current.json. This is the only place a
// packaged Lynk build's Node/monitor/bootstrap should ever run from — the
// app bundle itself is seed input only (see TODO.md's fixed runtime
// boundary). install.json (Control identity/state) is never touched here;
// existing installs keep their identity untouched.
import { realpath } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, relative, sep } from "node:path";
import {
  readManifestFile,
  runtimePointerIdentityMismatch,
  runtimeSidecarIdentity,
  runtimeVersionId,
  verifyRuntimeManifest
} from "./runtime-manifest.js";
import { CURRENT_POINTER_FILE, PREVIOUS_POINTER_FILE, readPointerFile, writePointerFile } from "./runtime-pointer.js";
import { runBundledRuntimeSmokeCheck } from "./runtime-smoke-check.js";
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
 * Existing-runtime authority, forward only: a manifest-verified install that
 * `current.json` already points at is kept, *unless* the app's own seed is
 * newer. An older seed must never displace a newer runtime — reinstalling an
 * old DMG once should not roll a machine back. But the reverse was also true
 * before, and that was the bug: a machine that had an older Lynk installed
 * kept running that old Gateway runtime forever no matter how many times the
 * app was updated, because the seed was never even read. The app and the
 * runtime it ships with have to move together.
 *
 * "Newer" is the manifest's `generatedAt`, the only ordered field the two have
 * in common: gatewayVersion is a release string that does not change on every
 * payload change, and gatewayBuildId is a content hash with no ordering.
 * See seedSupersedes for what happens when it cannot be compared.
 */
export async function ensureRuntimeInstalled({
  seedRoot,
  runtimeRoot = defaultRuntimeRoot(),
  smokeCheck = runBundledRuntimeSmokeCheck
}) {
  const existing = await currentRuntimeIfValid(runtimeRoot);
  if (existing && !(await seedSupersedes(seedRoot, existing))) return existing;

  // Same advisory lock as the updater's mutations: the provisioner runs on
  // every app launch and can otherwise interleave its rm/rename staging with
  // a user-driven stage/activate over the same versions/ tree.
  return withRuntimeLock(runtimeRoot, async () => {
    // Re-check under the lock: whoever held it may have just installed.
    const installed = await currentRuntimeIfValid(runtimeRoot);
    if (installed && !(await seedSupersedes(seedRoot, installed))) return installed;

    const manifest = await readManifestFile(seedRoot);
    const versionDir = runtimeVersionId(manifest);
    const target = join(runtimeRoot, "versions", versionDir);

    if (!(await isValid(target, manifest))) {
      await stageAndActivate(seedRoot, runtimeRoot, target, manifest);
    }

    // Same gate the manual updater applies. A replacement that happens without
    // anyone asking must not be able to leave the machine pointed at a runtime
    // that cannot start, so a candidate that fails to execute is abandoned and
    // the working install stays current.
    if (installed) {
      try {
        await smokeCheck(target, manifest);
      } catch (error) {
        throw new Error(
          `seed runtime failed its smoke check, keeping ${installed.gatewayVersion} (${installed.gatewayBuildId}): ${error.message}`
        );
      }
      // Record what is being replaced so the app's rollback has a target. The
      // updater does this on every activation; an automatic upgrade that
      // skipped it would leave the user with no way back from a bad build.
      const currentPointer = await readPointerFile(runtimeRoot, CURRENT_POINTER_FILE);
      if (currentPointer) await writePointerFile(runtimeRoot, PREVIOUS_POINTER_FILE, currentPointer);
    }

    await activateCurrent(runtimeRoot, target, manifest);
    return {
      runtimeRoot: target,
      gatewayVersion: manifest.gatewayVersion,
      gatewayBuildId: manifest.gatewayBuildId,
      ...runtimeSidecarIdentity(manifest),
      generatedAt: manifest.generatedAt
    };
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
    if (runtimePointerIdentityMismatch(current, ownManifest)) {
      return null;
    }
    await verifyRuntimeManifest(current.runtimeRoot, ownManifest);
    return {
      runtimeRoot: current.runtimeRoot,
      gatewayVersion: current.gatewayVersion,
      gatewayBuildId: current.gatewayBuildId,
      ...runtimeSidecarIdentity(ownManifest),
      generatedAt: ownManifest.generatedAt,
      pinned: current.pinned === true
    };
  } catch {
    return null;
  }
}

/**
 * True only when the seed's manifest is provably newer than the installed one
 * *and* the user has not pinned what is installed. An unreadable seed
 * manifest, a seed timestamp that is absent or unparseable, or equal
 * timestamps all answer false: the installed runtime is known to work, so
 * anything short of proof leaves it alone.
 *
 * A missing timestamp on the *installed* side is the one asymmetry — the field
 * is written by every manifest that carries the current format version, so its
 * absence means the install predates it, which is exactly the case a newer
 * seed should replace.
 *
 * The pin is what makes rollback mean anything. Rolling back necessarily lands
 * on a runtime older than the seed that shipped it, so without the pin the
 * next launch would re-apply the very build the user just rejected. Choosing a
 * version explicitly in the updater clears it again.
 */
async function seedSupersedes(seedRoot, installed) {
  if (installed.pinned) return false;
  const installedAt = timestamp(installed.generatedAt) ?? 0;
  try {
    const seed = timestamp((await readManifestFile(seedRoot)).generatedAt);
    return seed !== null && seed > installedAt;
  } catch {
    return false;
  }
}

function timestamp(value) {
  if (typeof value !== "string") return null;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : null;
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

/**
 * `pinned` marks a runtime the user deliberately chose to stay on, which
 * ensureRuntimeInstalled will not replace with a newer seed. Only rollback
 * sets it; every other activation clears it, so picking a version explicitly
 * puts the machine back under normal updates.
 */
export async function activateCurrent(runtimeRoot, target, manifest, { pinned = false } = {}) {
  const payload = {
    formatVersion: 1,
    runtimeRoot: target,
    gatewayVersion: manifest.gatewayVersion,
    gatewayBuildId: manifest.gatewayBuildId,
    ...runtimeSidecarIdentity(manifest),
    activatedAt: new Date().toISOString(),
    ...(pinned ? { pinned: true } : {})
  };
  await writePointerFile(runtimeRoot, CURRENT_POINTER_FILE, payload);
  return payload;
}

export async function readCurrentRuntime(runtimeRoot = defaultRuntimeRoot()) {
  return readPointerFile(runtimeRoot, CURRENT_POINTER_FILE);
}
