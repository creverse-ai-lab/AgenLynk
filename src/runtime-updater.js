// Local Gateway runtime updater/rollback core: manages candidate runtime
// versions under runtimeRoot/versions/ once a runtime is already installed
// (see runtime-installer.js for the seed->first-install path this builds on).
// Six library operations — inspect, stage, validate, activate, rollback,
// prune — all return the same stable JSON envelope ({ ok, op, ... } or
// { ok: false, op, error: { code, message, ... } }) instead of throwing, so
// a caller (CLI, Swift, Monitor) can branch on `.ok` without a try/catch.
//
// This is a *local* updater: it only ever activates a candidate that is
// already staged under runtimeRoot/versions/ (copied there from a caller-
// supplied seedRoot by stageRuntimeCandidate). There is no network fetch, no
// update channel, and no arbitrary download here — that boundary is
// intentional (see TODO.md's fixed runtime boundary) and separate from
// developer `git pull` workflows, which never touch this file.
import { execFile } from "node:child_process";
import { mkdir, readdir, rm } from "node:fs/promises";
import { isAbsolute, join, relative, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { pathExists } from "./fs-paths.js";
import { GATEWAY_API_VERSION, UnsupportedGatewayApiVersionError } from "./gateway-api-version.js";
import { activateCurrent, defaultRuntimeRoot, isConfinedToVersions, readCurrentRuntime } from "./runtime-installer.js";
import { withRuntimeLock } from "./runtime-lock.js";
import { readManifestFile, verifyRuntimeManifest } from "./runtime-manifest.js";
import { PREVIOUS_POINTER_FILE, readPointerFile, writePointerFile } from "./runtime-pointer.js";
import { stageVerifiedRuntime } from "./runtime-staging.js";

export { defaultRuntimeRoot };

const execFileAsync = promisify(execFile);

/** Carries a stable machine-readable `code` (+ optional details) into the JSON envelope's `error` field. */
class RuntimeUpdaterError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "RuntimeUpdaterError";
    this.code = code;
    this.details = details;
  }
}

function envelopeError(error) {
  if (error instanceof RuntimeUpdaterError) return { code: error.code, message: error.message, ...error.details };
  return { code: error?.code ?? "INTERNAL_ERROR", message: error?.message ?? String(error) };
}

async function runOperation(op, fn) {
  try {
    const data = await fn();
    return { ok: true, op, ...data };
  } catch (error) {
    return { ok: false, op, error: envelopeError(error) };
  }
}

/**
 * Accepts either a list of blocker reason strings (e.g. MonitorState's
 * restartBlockers()) or a counts object (e.g. { activeSessions, activeTasks,
 * pendingInbox }) and normalizes both into a list of reasons. An empty list
 * means "no active-work blockers" — the only case activate/rollback proceed.
 */
function normalizeBlockers(blockers) {
  if (!blockers) return [];
  if (Array.isArray(blockers)) return blockers.filter((item) => typeof item === "string" && item);
  if (typeof blockers === "object") {
    return Object.entries(blockers)
      .filter(([, value]) => (typeof value === "number" ? value > 0 : Boolean(value)))
      .map(([key, value]) => `${key}:${value}`);
  }
  return [];
}

/** Lexical-only confinement check: usable before a candidate exists on disk (stage) as well as after. */
function resolveVersionTarget(runtimeRoot, versionId) {
  if (typeof versionId !== "string" || !versionId) {
    throw new RuntimeUpdaterError("INVALID_ARGS", "versionId is required");
  }
  const versionsRoot = join(runtimeRoot, "versions");
  const target = join(versionsRoot, versionId);
  const rel = relative(versionsRoot, target);
  if (rel === "" || rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
    throw new RuntimeUpdaterError("PATH_CONFINEMENT_VIOLATION", `versionId escapes the managed versions root: ${versionId}`);
  }
  return target;
}

/**
 * Full confinement check (lexical + realpath, via runtime-installer.js's
 * isConfinedToVersions) for a candidate that must already exist — this is
 * what catches a versions/<id> entry that is, or is reached through, a
 * symlink escaping runtimeRoot/versions/ after it was placed on disk.
 */
async function resolveExistingVersionTarget(runtimeRoot, versionId) {
  const target = resolveVersionTarget(runtimeRoot, versionId);
  if (!(await pathExists(target))) {
    throw new RuntimeUpdaterError("CANDIDATE_NOT_FOUND", `no staged candidate found for versionId: ${versionId}`);
  }
  if (!(await isConfinedToVersions(runtimeRoot, target))) {
    throw new RuntimeUpdaterError("PATH_CONFINEMENT_VIOLATION", `candidate is not confined to the managed versions root: ${versionId}`);
  }
  return target;
}

async function readCandidateManifest(root) {
  try {
    return await readManifestFile(root);
  } catch (error) {
    throw new RuntimeUpdaterError("CANDIDATE_MANIFEST_MISSING", `candidate runtime manifest is missing or unreadable: ${error.message}`);
  }
}

async function verifyCandidate(root, manifest) {
  try {
    await verifyRuntimeManifest(root, manifest);
  } catch (error) {
    throw new RuntimeUpdaterError("CANDIDATE_VERIFICATION_FAILED", error.message);
  }
}

/** Mirrors installer.js's evaluateGatewayCompatibility/assertSupportedGatewayApiVersion: exact-major match only. */
function assertSupportedGatewayApiVersion(manifest) {
  if (manifest.gatewayApiVersion === GATEWAY_API_VERSION) return;
  const error = new UnsupportedGatewayApiVersionError({ reportedGatewayApiVersion: manifest.gatewayApiVersion });
  const details = { reportedGatewayApiVersion: error.reportedGatewayApiVersion, supportedGatewayApiVersion: error.supportedGatewayApiVersion };
  if (error.requiredGatewayApiVersion !== undefined) details.requiredGatewayApiVersion = error.requiredGatewayApiVersion;
  throw new RuntimeUpdaterError(error.code, error.message, details);
}

/**
 * Deterministic pre/post-activation smoke check: actually executes the
 * candidate's *own bundled* node binary (not the host Node running this
 * process) to import its own src/version.js and src/gateway-api-version.js,
 * and compares what it reports against the manifest. This is deliberately
 * more than checksum verification (which only proves the bytes on disk match
 * the manifest) — it proves the bundled runtime can actually execute JS and
 * resolve its own modules. No network access, no shell string, no
 * randomness: same target -> same result every time.
 */
async function runBuiltinSmokeCheck(target, manifest) {
  const nodeBinary = join(target, "node", "bin", "node");
  const versionModuleUrl = pathToFileURL(join(target, "src", "version.js")).href;
  const apiModuleUrl = pathToFileURL(join(target, "src", "gateway-api-version.js")).href;
  const script = `(async () => {
    const [versionUrl, apiUrl] = process.argv.slice(1);
    const version = await import(versionUrl);
    const api = await import(apiUrl);
    process.stdout.write(JSON.stringify({
      gatewayVersion: version.GATEWAY_VERSION,
      gatewayBuildId: version.GATEWAY_BUILD_ID,
      gatewayApiVersion: api.GATEWAY_API_VERSION
    }));
  })().catch((error) => {
    process.stderr.write(String((error && error.stack) || error));
    process.exit(1);
  });`;

  let stdout;
  try {
    ({ stdout } = await execFileAsync(nodeBinary, ["-e", script, versionModuleUrl, apiModuleUrl], { timeout: 10_000 }));
  } catch (error) {
    throw new RuntimeUpdaterError("SMOKE_CHECK_FAILED", `bundled runtime smoke check failed to execute: ${error.message}`);
  }

  let reported;
  try {
    reported = JSON.parse(stdout);
  } catch {
    throw new RuntimeUpdaterError("SMOKE_CHECK_FAILED", "bundled runtime smoke check produced non-JSON output");
  }
  if (
    reported.gatewayVersion !== manifest.gatewayVersion
    || reported.gatewayBuildId !== manifest.gatewayBuildId
    || reported.gatewayApiVersion !== manifest.gatewayApiVersion
  ) {
    throw new RuntimeUpdaterError("SMOKE_CHECK_FAILED", "bundled runtime smoke check reported an identity mismatch", { reported });
  }
  return reported;
}

async function runSmokeCheck(check, target, manifest) {
  try {
    return await check(target, manifest);
  } catch (error) {
    if (error instanceof RuntimeUpdaterError) throw error;
    throw new RuntimeUpdaterError("SMOKE_CHECK_FAILED", error.message);
  }
}

async function assertKnownGoodPointer(runtimeRoot, pointer, label) {
  if (!pointer) return null;
  if (!(await isConfinedToVersions(runtimeRoot, pointer.runtimeRoot))) {
    throw new RuntimeUpdaterError(
      "PATH_CONFINEMENT_VIOLATION",
      `${label} target is not confined to the managed versions root`
    );
  }
  const manifest = await readCandidateManifest(pointer.runtimeRoot);
  await verifyCandidate(pointer.runtimeRoot, manifest);
  if (
    manifest.gatewayVersion !== pointer.gatewayVersion
    || manifest.gatewayBuildId !== pointer.gatewayBuildId
  ) {
    throw new RuntimeUpdaterError(
      "RUNTIME_POINTER_IDENTITY_MISMATCH",
      `${label} target does not match its runtime manifest`,
      { pointer: label }
    );
  }
  return pointer;
}

export async function readPreviousRuntime(runtimeRoot = defaultRuntimeRoot()) {
  return readPointerFile(runtimeRoot, PREVIOUS_POINTER_FILE);
}

/** inspect: read-only report of current/previous pointers and every staged version. Never mutates. */
export async function inspectRuntime(options) {
  return runOperation("inspect", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), deep = false } = options ?? {};
    const current = await readCurrentRuntime(runtimeRoot);
    const previous = await readPointerFile(runtimeRoot, PREVIOUS_POINTER_FILE);
    const versionsRoot = join(runtimeRoot, "versions");

    let entries;
    try {
      entries = await readdir(versionsRoot, { withFileTypes: true });
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      entries = [];
    }

    const versions = [];
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      const target = join(versionsRoot, entry.name);
      const summary = {
        versionId: entry.name,
        runtimeRoot: target,
        isCurrent: current?.runtimeRoot === target,
        isPrevious: previous?.runtimeRoot === target
      };
      try {
        const manifest = await readManifestFile(target);
        summary.gatewayVersion = manifest.gatewayVersion;
        summary.gatewayBuildId = manifest.gatewayBuildId;
        summary.gatewayApiVersion = manifest.gatewayApiVersion;
        // Surfaced so the app can show which Node each installed runtime
        // carries without opening the manifest a second time.
        summary.nodeVersion = manifest.nodeVersion;
        summary.apiCompatible = manifest.gatewayApiVersion === GATEWAY_API_VERSION;
        if (deep) {
          try {
            await verifyRuntimeManifest(target, manifest);
            summary.verified = true;
          } catch (error) {
            summary.verified = false;
            summary.verificationError = error.message;
          }
        }
      } catch (error) {
        summary.manifestError = error.message;
      }
      versions.push(summary);
    }

    return { runtimeRoot, current, previous, versions };
  });
}

/**
 * stage: manifest/checksum-verify a seed and copy it into
 * runtimeRoot/versions/<gatewayVersion>-<gatewayBuildId>/ without touching
 * current.json. Idempotent — re-staging an already-valid target is a no-op.
 * Mirrors runtime-installer.js's stageAndActivate, minus the activation step.
 */
export async function stageRuntimeCandidate(options) {
  return runOperation("stage", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), seedRoot } = options ?? {};
    return withRuntimeLock(runtimeRoot, async () => {
    if (typeof seedRoot !== "string" || !seedRoot) {
      throw new RuntimeUpdaterError("INVALID_ARGS", "seedRoot is required");
    }

    const manifest = await readCandidateManifest(seedRoot);
    await verifyCandidate(seedRoot, manifest);
    assertSupportedGatewayApiVersion(manifest);

    const versionId = `${manifest.gatewayVersion}-${manifest.gatewayBuildId}`;
    const target = resolveVersionTarget(runtimeRoot, versionId);

    if (await pathExists(target)) {
      if (!(await isConfinedToVersions(runtimeRoot, target))) {
        throw new RuntimeUpdaterError("PATH_CONFINEMENT_VIOLATION", `staged candidate path is not confined to the managed versions root: ${versionId}`);
      }
      try {
        await verifyRuntimeManifest(target, manifest);
        return {
          versionId,
          runtimeRoot: target,
          gatewayVersion: manifest.gatewayVersion,
          gatewayBuildId: manifest.gatewayBuildId,
          gatewayApiVersion: manifest.gatewayApiVersion,
          alreadyStaged: true
        };
      } catch {
        // Falls through to re-stage: the existing target no longer matches
        // its own manifest (corrupted), same as installer.js's isValid().
      }

      const [current, previous] = await Promise.all([
        readCurrentRuntime(runtimeRoot),
        readPointerFile(runtimeRoot, PREVIOUS_POINTER_FILE)
      ]);
      if (current?.runtimeRoot === target || previous?.runtimeRoot === target) {
        throw new RuntimeUpdaterError(
          "PROTECTED_TARGET_CORRUPT",
          "refusing to replace a corrupt current or previous runtime during staging"
        );
      }
    }

    await stageVerifiedRuntime({
      seedRoot,
      runtimeRoot,
      target,
      manifest,
      isConfined: isConfinedToVersions,
      onFailure: (error) =>
        new RuntimeUpdaterError("STAGING_FAILED", `candidate failed validation, staging aborted: ${error.message}`),
      onConfinementViolation: () =>
        new RuntimeUpdaterError("PATH_CONFINEMENT_VIOLATION", `staged candidate resolved outside the managed versions root: ${versionId}`)
    });

    return {
      versionId,
      runtimeRoot: target,
      gatewayVersion: manifest.gatewayVersion,
      gatewayBuildId: manifest.gatewayBuildId,
      gatewayApiVersion: manifest.gatewayApiVersion,
      alreadyStaged: false
    };
    });
  });
}

function versionsRootOf(runtimeRoot) {
  return join(runtimeRoot, "versions");
}

/**
 * validate: re-verify a staged candidate's manifest/checksum, Gateway API
 * compatibility, and run the deterministic bundled-runtime smoke check —
 * without activating it. `smokeCheck` may be an async callback; the CLI
 * never exposes this (it always uses the builtin check).
 */
export async function validateRuntimeCandidate(options) {
  return runOperation("validate", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), versionId, smokeCheck } = options ?? {};
    return withRuntimeLock(runtimeRoot, async () => {
    const target = await resolveExistingVersionTarget(runtimeRoot, versionId);
    const manifest = await readCandidateManifest(target);
    await verifyCandidate(target, manifest);
    assertSupportedGatewayApiVersion(manifest);
    const smoke = await runSmokeCheck(smokeCheck ?? runBuiltinSmokeCheck, target, manifest);

    return {
      versionId,
      runtimeRoot: target,
      gatewayVersion: manifest.gatewayVersion,
      gatewayBuildId: manifest.gatewayBuildId,
      gatewayApiVersion: manifest.gatewayApiVersion,
      smoke
    };
    });
  });
}

/**
 * activate: switch current.json to a validated candidate, keeping the prior
 * current as `previous.json` (the "previous known-good target"). Rejects
 * up front if the caller reports active-work blockers. If the
 * post-activation health check fails, current.json is atomically restored
 * to the previous target before returning the failure.
 */
export async function activateRuntimeCandidate(options) {
  return runOperation("activate", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), versionId, blockers, smokeCheck, healthCheck } = options ?? {};
    return withRuntimeLock(runtimeRoot, async () => {

    const blockerList = normalizeBlockers(blockers);
    if (blockerList.length) {
      throw new RuntimeUpdaterError("ACTIVATION_BLOCKED", "activation deferred: active work is in progress", { blockers: blockerList });
    }

    const target = await resolveExistingVersionTarget(runtimeRoot, versionId);
    const manifest = await readCandidateManifest(target);
    await verifyCandidate(target, manifest);
    assertSupportedGatewayApiVersion(manifest);
    await runSmokeCheck(smokeCheck ?? runBuiltinSmokeCheck, target, manifest);

    const previousBeforeSwitch = await assertKnownGoodPointer(
      runtimeRoot,
      await readCurrentRuntime(runtimeRoot),
      "current"
    );
    if (previousBeforeSwitch) {
      await writePointerFile(runtimeRoot, PREVIOUS_POINTER_FILE, previousBeforeSwitch);
    }
    await activateCurrent(runtimeRoot, target, manifest);

    try {
      await runSmokeCheck(healthCheck ?? runBuiltinSmokeCheck, target, manifest);
    } catch (healthError) {
      if (previousBeforeSwitch) {
        await activateCurrent(runtimeRoot, previousBeforeSwitch.runtimeRoot, previousBeforeSwitch);
      } else {
        await rm(join(runtimeRoot, "current.json"), { force: true });
      }
      throw new RuntimeUpdaterError(
        "POST_ACTIVATION_HEALTH_CHECK_FAILED",
        `post-activation health check failed, restored previous target: ${healthError.message}`,
        {
          attempted: { gatewayVersion: manifest.gatewayVersion, gatewayBuildId: manifest.gatewayBuildId },
          restoredTo: previousBeforeSwitch
            ? { gatewayVersion: previousBeforeSwitch.gatewayVersion, gatewayBuildId: previousBeforeSwitch.gatewayBuildId }
            : null
        }
      );
    }

    return {
      activated: {
        versionId,
        runtimeRoot: target,
        gatewayVersion: manifest.gatewayVersion,
        gatewayBuildId: manifest.gatewayBuildId,
        gatewayApiVersion: manifest.gatewayApiVersion
      },
      previous: previousBeforeSwitch
        ? { runtimeRoot: previousBeforeSwitch.runtimeRoot, gatewayVersion: previousBeforeSwitch.gatewayVersion, gatewayBuildId: previousBeforeSwitch.gatewayBuildId }
        : null
    };
    });
  });
}

/**
 * rollback: restore current.json to the recorded previous target. Rejects
 * up front on active-work blockers, same as activate. Swaps previous.json
 * to the target being rolled back *from*, so a rollback can itself be
 * rolled back.
 */
export async function rollbackRuntime(options) {
  return runOperation("rollback", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), blockers, smokeCheck, healthCheck } = options ?? {};
    return withRuntimeLock(runtimeRoot, async () => {

    const blockerList = normalizeBlockers(blockers);
    if (blockerList.length) {
      throw new RuntimeUpdaterError("ROLLBACK_BLOCKED", "rollback deferred: active work is in progress", { blockers: blockerList });
    }

    const previous = await readPointerFile(runtimeRoot, PREVIOUS_POINTER_FILE);
    if (!previous) throw new RuntimeUpdaterError("NO_PREVIOUS_TARGET", "no previous target is recorded to roll back to");
    if (!(await isConfinedToVersions(runtimeRoot, previous.runtimeRoot))) {
      throw new RuntimeUpdaterError("PATH_CONFINEMENT_VIOLATION", "recorded previous target is no longer confined to the managed versions root");
    }

    const manifest = await readCandidateManifest(previous.runtimeRoot);
    await verifyCandidate(previous.runtimeRoot, manifest);
    if (
      manifest.gatewayVersion !== previous.gatewayVersion
      || manifest.gatewayBuildId !== previous.gatewayBuildId
    ) {
      throw new RuntimeUpdaterError(
        "PREVIOUS_TARGET_IDENTITY_MISMATCH",
        "recorded previous target does not match its runtime manifest"
      );
    }
    assertSupportedGatewayApiVersion(manifest);
    await runSmokeCheck(smokeCheck ?? runBuiltinSmokeCheck, previous.runtimeRoot, manifest);

    const currentBeforeRollback = await assertKnownGoodPointer(
      runtimeRoot,
      await readCurrentRuntime(runtimeRoot),
      "current"
    );
    await activateCurrent(runtimeRoot, previous.runtimeRoot, previous);
    try {
      await runSmokeCheck(healthCheck ?? runBuiltinSmokeCheck, previous.runtimeRoot, manifest);
    } catch (healthError) {
      if (currentBeforeRollback) {
        await activateCurrent(runtimeRoot, currentBeforeRollback.runtimeRoot, currentBeforeRollback);
      } else {
        await rm(join(runtimeRoot, "current.json"), { force: true });
      }
      throw new RuntimeUpdaterError(
        "POST_ROLLBACK_HEALTH_CHECK_FAILED",
        `post-rollback health check failed, restored current target: ${healthError.message}`,
        {
          attempted: { gatewayVersion: previous.gatewayVersion, gatewayBuildId: previous.gatewayBuildId },
          restoredTo: currentBeforeRollback
            ? { gatewayVersion: currentBeforeRollback.gatewayVersion, gatewayBuildId: currentBeforeRollback.gatewayBuildId }
            : null
        }
      );
    }
    if (currentBeforeRollback) {
      await writePointerFile(runtimeRoot, PREVIOUS_POINTER_FILE, currentBeforeRollback);
    }

    return {
      activated: { runtimeRoot: previous.runtimeRoot, gatewayVersion: previous.gatewayVersion, gatewayBuildId: previous.gatewayBuildId },
      rolledBackFrom: currentBeforeRollback
        ? { runtimeRoot: currentBeforeRollback.runtimeRoot, gatewayVersion: currentBeforeRollback.gatewayVersion, gatewayBuildId: currentBeforeRollback.gatewayBuildId }
        : null
    };
    });
  });
}

/**
 * prune: remove staged versions/<id> directories that are neither the
 * current nor previous target, nor explicitly kept. Never touches
 * current.json/previous.json/staging/. Every removal path is re-confirmed
 * confined to runtimeRoot/versions/ immediately before it is removed.
 */
export async function pruneRuntimeVersions(options) {
  return runOperation("prune", async () => {
    const { runtimeRoot = defaultRuntimeRoot(), keep = [] } = options ?? {};
    return withRuntimeLock(runtimeRoot, async () => {
    if (!Array.isArray(keep)) throw new RuntimeUpdaterError("INVALID_ARGS", "keep must be an array of versionId strings");

    const versionsRoot = versionsRootOf(runtimeRoot);
    const current = await readCurrentRuntime(runtimeRoot);
    const previous = await readPointerFile(runtimeRoot, PREVIOUS_POINTER_FILE);
    const protectedIds = new Set(
      [current?.runtimeRoot, previous?.runtimeRoot]
        .filter(Boolean)
        .map((path) => relative(versionsRoot, path))
    );
    for (const id of keep) {
      if (typeof id === "string" && id) protectedIds.add(id);
    }

    let entries;
    try {
      entries = await readdir(versionsRoot, { withFileTypes: true });
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
      entries = [];
    }

    const removed = [];
    const skipped = [];
    for (const entry of entries) {
      if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
      if (protectedIds.has(entry.name)) {
        skipped.push(entry.name);
        continue;
      }
      const candidate = join(versionsRoot, entry.name);
      if (!(await isConfinedToVersions(runtimeRoot, candidate))) {
        skipped.push(entry.name);
        continue;
      }
      await rm(candidate, { recursive: true, force: true });
      removed.push(entry.name);
    }

    return { removed, protected: [...protectedIds], skipped };
    });
  });
}
