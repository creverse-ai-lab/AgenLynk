// Copies the app bundle's runtime seed into a single, version-pinned install
// path (~/.acp-gateway/runtime/versions/<gatewayVersion>-<runtimeBuildId>/)
// and atomically activates it via current.json. This is the only place a
// packaged Lynk build's Node/monitor/bootstrap should ever run from — the
// app bundle itself is seed input only (see TODO.md's fixed runtime
// boundary). install.json (Control identity/state) is never touched here;
// existing installs keep their identity untouched.
import { access, readdir, readlink, realpath, rename, rm, symlink } from "node:fs/promises";
import { homedir } from "node:os";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
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
 * newer *and* active-work state is explicitly known to be idle. An older seed
 * must never displace a newer runtime — reinstalling an old DMG once should
 * not roll a machine back. A newer seed is staged either way, but unknown
 * Gateway state or non-empty blockers leave the current pointer and symlink
 * untouched. First install (no valid current) still activates.
 *
 * "Newer" is the manifest's `generatedAt`, the only ordered field the two have
 * in common: gatewayVersion is a release string that does not change on every
 * payload change, and gatewayBuildId is a content hash with no ordering.
 * See seedSupersedes for what happens when it cannot be compared.
 */
/**
 * Startup upgrades must not treat missing active-work state as "idle".
 * Omitted/null/non-structured `blockers` is unknown → defer. Only an
 * explicit empty list or all-zero counts object is permission to activate.
 * First install (no valid current) does not consult this.
 */
export function resolveStartupBlockers(blockers) {
  if (blockers === undefined || blockers === null) {
    return { allowed: false, unknown: true, reasons: ["active-work state unknown"] };
  }
  if (Array.isArray(blockers)) {
    const reasons = blockers.filter((item) => typeof item === "string" && item);
    return { allowed: reasons.length === 0, unknown: false, reasons };
  }
  if (typeof blockers === "object") {
    const reasons = Object.entries(blockers)
      .filter(([, value]) => (typeof value === "number" ? value > 0 : Boolean(value)))
      .map(([key, value]) => `${key}:${value}`);
    return { allowed: reasons.length === 0, unknown: false, reasons };
  }
  return { allowed: false, unknown: true, reasons: ["active-work state unknown"] };
}

export async function ensureRuntimeInstalled({
  seedRoot,
  runtimeRoot = defaultRuntimeRoot(),
  smokeCheck = runBundledRuntimeSmokeCheck,
  blockers
}) {
  const initialInspection = await inspectCurrentRuntime(runtimeRoot);
  const existing = initialInspection.runtime;
  if (existing && !(await seedSupersedes(seedRoot, existing))) return existing;

  // Same advisory lock as the updater's mutations: the provisioner runs on
  // every app launch and can otherwise interleave its rm/rename staging with
  // a user-driven stage/activate over the same versions/ tree.
  return withRuntimeLock(runtimeRoot, async () => {
    // Re-check under the lock: whoever held it may have just installed.
    const inspection = await inspectCurrentRuntime(runtimeRoot);
    let installed = inspection.runtime;
    const recoveryNotice = inspection.issue
      ? `기존 current.json 또는 runtime이 손상되어 안전 복구가 필요합니다: ${inspection.issue}`
      : null;
    let repairingManagedRuntime = false;

    if (!installed && inspection.issue) {
      const recovered = await runtimeFromCurrentSymlinkIfValid(runtimeRoot);
      if (recovered) {
        // The stable symlink still identifies the runtime already in use. Repair
        // only the pointer metadata; do not switch versions or bypass blockers.
        await activateCurrent(runtimeRoot, recovered.runtimeRoot, recovered, { pinned: recovered.pinned });
        installed = recovered;
      } else {
        repairingManagedRuntime = await hasManagedRuntimeVersions(runtimeRoot);
      }
    }
    if (installed && !(await seedSupersedes(seedRoot, installed))) {
      return recoveryNotice ? { ...installed, recoveryNotice } : installed;
    }

    const manifest = await readManifestFile(seedRoot);
    const versionDir = runtimeVersionId(manifest);
    const target = join(runtimeRoot, "versions", versionDir);

    if (!(await isValid(target, manifest))) {
      await stageAndActivate(seedRoot, runtimeRoot, target, manifest);
    }

    // A newer seed may be staged while work is in flight or while Gateway
    // state cannot be read. Activation still requires an explicit all-clear.
    // Missing blockers is unknown, not idle — the provisioner therefore
    // stages on launch and leaves current.json / current untouched.
    if (installed || repairingManagedRuntime) {
      const decision = resolveStartupBlockers(blockers);
      if (!decision.allowed) {
        if (installed) return recoveryNotice ? { ...installed, recoveryNotice } : installed;
        throw new Error(
          `기존 runtime을 안전하게 확인할 수 없어 bundled runtime 활성화를 보류합니다 (${decision.reasons.join(", ")})`
        );
      }

      try {
        await smokeCheck(target, manifest);
      } catch (error) {
        throw new Error(
          installed
            ? `seed runtime failed its smoke check, keeping ${installed.gatewayVersion} (${installed.gatewayBuildId}): ${error.message}`
            : `seed runtime failed its smoke check while repairing an invalid current runtime: ${error.message}`
        );
      }
      // Record what is being replaced so the app's rollback has a target. The
      // updater does this on every activation; an automatic upgrade that
      // skipped it would leave the user with no way back from a bad build.
      if (installed) {
        const currentPointer = await readPointerFile(runtimeRoot, CURRENT_POINTER_FILE);
        if (currentPointer) await writePointerFile(runtimeRoot, PREVIOUS_POINTER_FILE, currentPointer);
      }
    }

    await activateCurrent(runtimeRoot, target, manifest);
    return {
      runtimeRoot: target,
      gatewayVersion: manifest.gatewayVersion,
      gatewayBuildId: manifest.gatewayBuildId,
      runtimeBuildId: manifest.runtimeBuildId,
      ...runtimeSidecarIdentity(manifest),
      generatedAt: manifest.generatedAt,
      ...(recoveryNotice ? { recoveryNotice } : {})
    };
  });
}

async function inspectCurrentRuntime(runtimeRoot) {
  const pointerPath = join(runtimeRoot, CURRENT_POINTER_FILE);
  try {
    await access(pointerPath);
  } catch (error) {
    if (error?.code === "ENOENT") return { runtime: null, issue: null };
    return { runtime: null, issue: `current.json을 읽을 수 없습니다: ${error.message}` };
  }
  try {
    const current = await readCurrentRuntime(runtimeRoot);
    if (!current) return { runtime: null, issue: "current.json 형식이 올바르지 않습니다" };
    if (!(await isConfinedToVersions(runtimeRoot, current.runtimeRoot))) {
      return { runtime: null, issue: "current runtime이 관리되는 versions 경로 밖을 가리킵니다" };
    }
    const ownManifest = await readManifestFile(current.runtimeRoot);
    if (runtimePointerIdentityMismatch(current, ownManifest)) {
      return { runtime: null, issue: "current.json identity가 runtime manifest와 일치하지 않습니다" };
    }
    await verifyRuntimeManifest(current.runtimeRoot, ownManifest);
    return {
      runtime: runtimeInfo(current.runtimeRoot, ownManifest, { pinned: current.pinned === true }),
      issue: null
    };
  } catch (error) {
    return { runtime: null, issue: error?.message ?? String(error) };
  }
}

async function runtimeFromCurrentSymlinkIfValid(runtimeRoot) {
  try {
    const linkTarget = await readlink(join(runtimeRoot, "current"));
    const target = isAbsolute(linkTarget) ? linkTarget : resolve(runtimeRoot, linkTarget);
    if (!(await isConfinedToVersions(runtimeRoot, target))) return null;
    const manifest = await readManifestFile(target);
    await verifyRuntimeManifest(target, manifest);
    return runtimeInfo(target, manifest);
  } catch {
    return null;
  }
}

function runtimeInfo(runtimeRoot, manifest, { pinned = false } = {}) {
  return {
    runtimeRoot,
    gatewayVersion: manifest.gatewayVersion,
    gatewayBuildId: manifest.gatewayBuildId,
    runtimeBuildId: manifest.runtimeBuildId,
    ...runtimeSidecarIdentity(manifest),
    generatedAt: manifest.generatedAt,
    pinned
  };
}

async function hasManagedRuntimeVersions(runtimeRoot) {
  try {
    const entries = await readdir(join(runtimeRoot, "versions"), { withFileTypes: true });
    return entries.some((entry) => entry.isDirectory());
  } catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
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
    runtimeBuildId: manifest.runtimeBuildId,
    ...runtimeSidecarIdentity(manifest),
    activatedAt: new Date().toISOString(),
    ...(pinned ? { pinned: true } : {})
  };
  await writePointerFile(runtimeRoot, CURRENT_POINTER_FILE, payload);
  await updateCurrentSymlink(runtimeRoot, target);
  return payload;
}

/** Drops both authorities together so a failed first activation cannot leave current.json and the stable symlink pointing at different things. */
export async function clearCurrentActivation(runtimeRoot) {
  await rm(join(runtimeRoot, CURRENT_POINTER_FILE), { force: true });
  await rm(join(runtimeRoot, "current"), { force: true });
}

/**
 * Maintains a stable `<runtimeRoot>/current` symlink pointing at the active
 * version directory, updated atomically on every activation. External
 * references — chiefly each agent's Control MCP config — can point through it
 * (`current/node/bin/node`, `current/gateway/src/index.js`) and keep working across
 * runtime updates, instead of pinning a version dir that goes stale the moment
 * a newer runtime activates. Best-effort: a filesystem without symlinks must
 * not break activation, so failure is swallowed.
 */
async function updateCurrentSymlink(runtimeRoot, target) {
  const link = join(runtimeRoot, "current");
  const temporary = join(runtimeRoot, `current.link.${process.pid}.tmp`);
  // Relative target so the link survives the runtime tree being relocated.
  const relativeTarget = relative(runtimeRoot, target);
  try {
    await rm(temporary, { force: true });
    await symlink(relativeTarget, temporary);
    await rename(temporary, link); // atomic replace on the same volume
  } catch {
    await rm(temporary, { force: true }).catch(() => {});
  }
}

export async function readCurrentRuntime(runtimeRoot = defaultRuntimeRoot()) {
  return readPointerFile(runtimeRoot, CURRENT_POINTER_FILE);
}
