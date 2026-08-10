import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { chmod, cp, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { readCurrentRuntime } from "../src/runtime-installer.js";
import {
  activateRuntimeCandidate,
  inspectRuntime,
  pruneRuntimeVersions,
  readPreviousRuntime,
  rollbackRuntime,
  stageRuntimeCandidate,
  validateRuntimeCandidate
} from "../src/runtime-updater.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

const cliPath = fileURLToPath(new URL("../src/runtime-updater-cli.js", import.meta.url));

// Builds on writeRuntimeSeed but swaps node/bin/node for a shim that still
// answers `--version` deterministically (for manifest verification) while
// delegating anything else to the real system `node` — letting the default
// builtin smoke check actually execute the candidate's own src files through
// its "own" bundled Node, without needing a real bundled Node binary in tests.
async function writeSmokeCapableSeed(root, options = {}) {
  await writeRuntimeSeed(root, options);
  const nodeVersion = options.nodeVersion ?? "22.14.0";
  const nodePath = join(root, "node/bin/node");
  await writeFile(
    nodePath,
    `#!/bin/sh\nif [ "$1" = "--version" ]; then\n  echo "v${nodeVersion}"\nelse\n  exec node "$@"\nfi\n`
  );
  await chmod(nodePath, 0o755);
  const manifest = await buildRuntimeManifest(root);
  await writeFile(join(root, "runtime-manifest.json"), JSON.stringify(manifest));
  return manifest;
}

function noopSmokeCheck() {
  return { ok: true };
}

function runCli(args) {
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [cliPath, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => { stdout += chunk; });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("error", reject);
    child.once("close", (code) => resolve({ code, stdout, stderr }));
  });
}

test("stage -> validate -> activate -> inspect succeeds end to end via the real builtin smoke check", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const seed = join(workspace, "seed-1");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "1.0.0", gatewayBuildId: "build1" });
    const runtimeRoot = join(workspace, "runtime");

    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });
    assert.equal(staged.ok, true);
    assert.equal(staged.op, "stage");
    assert.equal(staged.versionId, "1.0.0-build1");
    assert.equal(staged.alreadyStaged, false);

    const restaged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });
    assert.equal(restaged.alreadyStaged, true, "re-staging an already-valid target is idempotent");

    const validated = await validateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId });
    assert.equal(validated.ok, true);
    assert.equal(validated.smoke.gatewayVersion, "1.0.0");

    const activated = await activateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId });
    assert.equal(activated.ok, true);
    assert.equal(activated.activated.gatewayVersion, "1.0.0");
    assert.equal(activated.previous, null, "first-ever activation has no previous target");

    const current = await readCurrentRuntime(runtimeRoot);
    assert.equal(current.gatewayVersion, "1.0.0");

    const inspected = await inspectRuntime({ runtimeRoot });
    assert.equal(inspected.ok, true);
    assert.equal(inspected.versions.length, 1);
    assert.equal(inspected.versions[0].isCurrent, true);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("stage rejects a candidate whose payload was tampered with after its manifest was generated", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const seed = join(workspace, "seed-tampered");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "2.0.0", gatewayBuildId: "build2" });
    await writeFile(join(seed, "src/monitor.js"), "export default { tampered: true };\n");

    const result = await stageRuntimeCandidate({ runtimeRoot: join(workspace, "runtime"), seedRoot: seed });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "CANDIDATE_VERIFICATION_FAILED");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("stage never replaces a corrupt current target in place", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const seed = join(workspace, "seed-protected-current");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "2.1.0", gatewayBuildId: "build-protected" });
    const runtimeRoot = join(workspace, "runtime");
    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });
    await activateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const current = await readCurrentRuntime(runtimeRoot);
    const corruptedPath = join(current.runtimeRoot, "src/monitor.js");
    const corruptedBytes = "export default { corrupted: true };\n";
    await writeFile(corruptedPath, corruptedBytes);

    const restage = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });
    assert.equal(restage.ok, false);
    assert.equal(restage.error.code, "PROTECTED_TARGET_CORRUPT");
    assert.equal(await readFile(corruptedPath, "utf8"), corruptedBytes);
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeRoot, current.runtimeRoot);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("stage rejects a candidate reporting an incompatible gatewayApiVersion", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const seed = join(workspace, "seed-incompatible");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "3.0.0", gatewayBuildId: "build3", gatewayApiVersion: 999 });

    const result = await stageRuntimeCandidate({ runtimeRoot: join(workspace, "runtime"), seedRoot: seed });
    assert.equal(result.ok, false);
    assert.equal(result.error.code, "UNSUPPORTED_GATEWAY_API_VERSION");
    assert.equal(result.error.reportedGatewayApiVersion, 999);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("activate rejects a traversal versionId and a symlink that escapes runtimeRoot/versions", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    const traversal = await activateRuntimeCandidate({ runtimeRoot, versionId: "../../etc" });
    assert.equal(traversal.ok, false);
    assert.equal(traversal.error.code, "PATH_CONFINEMENT_VIOLATION");

    const outside = join(workspace, "elsewhere");
    await writeSmokeCapableSeed(outside, { gatewayVersion: "4.0.0", gatewayBuildId: "build4" });
    await mkdir(join(runtimeRoot, "versions"), { recursive: true });
    await symlink(outside, join(runtimeRoot, "versions", "escape"), "dir");

    const escape = await activateRuntimeCandidate({ runtimeRoot, versionId: "escape" });
    assert.equal(escape.ok, false);
    assert.equal(escape.error.code, "PATH_CONFINEMENT_VIOLATION");
    assert.equal(await readCurrentRuntime(runtimeRoot), null, "current.json must remain untouched");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("activate and rollback both reject with a stable blocked error when active-work blockers are reported", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const seed = join(workspace, "seed-blockers");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "5.0.0", gatewayBuildId: "build5" });
    const runtimeRoot = join(workspace, "runtime");
    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });

    const blockedActivate = await activateRuntimeCandidate({
      runtimeRoot,
      versionId: staged.versionId,
      blockers: { activeSessions: 1, activeTasks: 0, pendingInbox: 0 }
    });
    assert.equal(blockedActivate.ok, false);
    assert.equal(blockedActivate.error.code, "ACTIVATION_BLOCKED");
    assert.deepEqual(blockedActivate.error.blockers, ["activeSessions:1"]);
    assert.equal(await readCurrentRuntime(runtimeRoot), null, "a blocked activation must not touch current.json");

    const blockedRollback = await rollbackRuntime({ runtimeRoot, blockers: ["진행 중 Task 1개"] });
    assert.equal(blockedRollback.ok, false);
    assert.equal(blockedRollback.error.code, "ROLLBACK_BLOCKED");
    assert.deepEqual(blockedRollback.error.blockers, ["진행 중 Task 1개"]);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("activate atomically restores the previous target when the post-activation health check fails", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    const seedOne = join(workspace, "seed-6a");
    await writeSmokeCapableSeed(seedOne, { gatewayVersion: "6.0.0", gatewayBuildId: "build6a" });
    const stagedOne = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedOne });
    const activatedOne = await activateRuntimeCandidate({ runtimeRoot, versionId: stagedOne.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });
    assert.equal(activatedOne.ok, true);

    const seedTwo = join(workspace, "seed-6b");
    await writeSmokeCapableSeed(seedTwo, { gatewayVersion: "6.0.0", gatewayBuildId: "build6b" });
    const stagedTwo = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedTwo });

    const failedActivation = await activateRuntimeCandidate({
      runtimeRoot,
      versionId: stagedTwo.versionId,
      smokeCheck: noopSmokeCheck,
      healthCheck: async () => { throw new Error("simulated health check failure"); }
    });
    assert.equal(failedActivation.ok, false);
    assert.equal(failedActivation.error.code, "POST_ACTIVATION_HEALTH_CHECK_FAILED");
    assert.equal(failedActivation.error.restoredTo.gatewayBuildId, "build6a");

    const current = await readCurrentRuntime(runtimeRoot);
    assert.equal(current.gatewayBuildId, "build6a", "current.json must be rolled back to the previous known-good target");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("rollback restores the previous target and reports NO_PREVIOUS_TARGET when nothing was recorded", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    const none = await rollbackRuntime({ runtimeRoot });
    assert.equal(none.ok, false);
    assert.equal(none.error.code, "NO_PREVIOUS_TARGET");

    const seedOne = join(workspace, "seed-7a");
    await writeSmokeCapableSeed(seedOne, { gatewayVersion: "7.0.0", gatewayBuildId: "build7a" });
    const stagedOne = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedOne });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedOne.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const seedTwo = join(workspace, "seed-7b");
    await writeSmokeCapableSeed(seedTwo, { gatewayVersion: "7.0.0", gatewayBuildId: "build7b" });
    const stagedTwo = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedTwo });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedTwo.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const rolledBack = await rollbackRuntime({ runtimeRoot });
    assert.equal(rolledBack.ok, true);
    assert.equal(rolledBack.activated.gatewayBuildId, "build7a");
    assert.equal(rolledBack.rolledBackFrom.gatewayBuildId, "build7b");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayBuildId, "build7a");
    assert.equal((await readPreviousRuntime(runtimeRoot)).gatewayBuildId, "build7b", "rollback must be itself reversible");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("rollback revalidates API compatibility and restores current when its health check fails", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const seedOne = join(workspace, "seed-rollback-guard-a");
    await writeSmokeCapableSeed(seedOne, { gatewayVersion: "7.1.0", gatewayBuildId: "build7guard-a" });
    const stagedOne = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedOne });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedOne.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const seedTwo = join(workspace, "seed-rollback-guard-b");
    await writeSmokeCapableSeed(seedTwo, { gatewayVersion: "7.1.0", gatewayBuildId: "build7guard-b" });
    const stagedTwo = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedTwo });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedTwo.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const failed = await rollbackRuntime({
      runtimeRoot,
      smokeCheck: noopSmokeCheck,
      healthCheck: async () => { throw new Error("simulated rollback health failure"); }
    });
    assert.equal(failed.ok, false);
    assert.equal(failed.error.code, "POST_ROLLBACK_HEALTH_CHECK_FAILED");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayBuildId, "build7guard-b");
    assert.equal((await readPreviousRuntime(runtimeRoot)).gatewayBuildId, "build7guard-a", "a failed rollback must remain retryable");

    const incompatibleSeed = join(workspace, "seed-rollback-incompatible");
    await writeSmokeCapableSeed(incompatibleSeed, {
      gatewayVersion: "7.1.0",
      gatewayBuildId: "build7guard-incompatible",
      gatewayApiVersion: 999
    });
    const incompatibleRoot = join(runtimeRoot, "versions", "7.1.0-build7guard-incompatible");
    await cp(incompatibleSeed, incompatibleRoot, { recursive: true, verbatimSymlinks: true });
    await writeFile(join(runtimeRoot, "previous.json"), JSON.stringify({
      formatVersion: 1,
      runtimeRoot: incompatibleRoot,
      gatewayVersion: "7.1.0",
      gatewayBuildId: "build7guard-incompatible",
      activatedAt: new Date().toISOString()
    }));
    const incompatible = await rollbackRuntime({ runtimeRoot, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });
    assert.equal(incompatible.ok, false);
    assert.equal(incompatible.error.code, "UNSUPPORTED_GATEWAY_API_VERSION");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayBuildId, "build7guard-b");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("prune removes only unprotected staged versions, never current or previous", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    const seedOne = join(workspace, "seed-8a");
    await writeSmokeCapableSeed(seedOne, { gatewayVersion: "8.0.0", gatewayBuildId: "build8a" });
    const stagedOne = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedOne });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedOne.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const seedTwo = join(workspace, "seed-8b");
    await writeSmokeCapableSeed(seedTwo, { gatewayVersion: "8.0.0", gatewayBuildId: "build8b" });
    const stagedTwo = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedTwo });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedTwo.versionId, smokeCheck: noopSmokeCheck, healthCheck: noopSmokeCheck });

    const seedThree = join(workspace, "seed-8c");
    await writeSmokeCapableSeed(seedThree, { gatewayVersion: "8.0.0", gatewayBuildId: "build8c" });
    const stagedThree = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seedThree });

    const pruned = await pruneRuntimeVersions({ runtimeRoot });
    assert.equal(pruned.ok, true);
    assert.deepEqual(pruned.removed, [stagedThree.versionId]);
    assert.ok(pruned.protected.includes(stagedOne.versionId), "previous target must be protected");
    assert.ok(pruned.protected.includes(stagedTwo.versionId), "current target must be protected");

    const stillCurrent = await readCurrentRuntime(runtimeRoot);
    assert.equal(stillCurrent.gatewayBuildId, "build8b");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("library operations return an ok:false envelope instead of throwing on malformed arguments", async () => {
  await assert.doesNotReject(async () => {
    const missingVersionId = await activateRuntimeCandidate({ runtimeRoot: "/tmp/does-not-matter" });
    assert.equal(missingVersionId.ok, false);
    assert.equal(missingVersionId.error.code, "INVALID_ARGS");

    const nullOptions = await activateRuntimeCandidate(null);
    assert.equal(nullOptions.ok, false);
    assert.equal(nullOptions.error.code, "INVALID_ARGS");

    const badKeep = await pruneRuntimeVersions({ runtimeRoot: "/tmp/does-not-matter", keep: "not-an-array" });
    assert.equal(badKeep.ok, false);
    assert.equal(badKeep.error.code, "INVALID_ARGS");
  });
});

test("CLI prints exactly one JSON envelope with a matching exit code for success, expected failure, and malformed args", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    const inspectRun = await runCli(["inspect", "--runtime-root", runtimeRoot]);
    assert.equal(inspectRun.code, 0);
    const inspectLines = inspectRun.stdout.trim().split("\n");
    assert.equal(inspectLines.length, 1, "CLI must print exactly one JSON line");
    const inspectBody = JSON.parse(inspectLines[0]);
    assert.equal(inspectBody.ok, true);
    assert.equal(inspectBody.current, null);

    const unknownOp = await runCli(["not-a-real-op", "--runtime-root", runtimeRoot]);
    assert.notEqual(unknownOp.code, 0);
    const unknownBody = JSON.parse(unknownOp.stdout.trim());
    assert.equal(unknownBody.ok, false);
    assert.equal(unknownBody.error.code, "INVALID_ARGS");

    const malformedBlockers = await runCli(["rollback", "--runtime-root", runtimeRoot, "--blockers", "{not-json"]);
    assert.notEqual(malformedBlockers.code, 0);
    const malformedBody = JSON.parse(malformedBlockers.stdout.trim());
    assert.equal(malformedBody.ok, false);
    assert.equal(malformedBody.error.code, "INVALID_ARGS");

    const seed = join(workspace, "seed-cli");
    await writeSmokeCapableSeed(seed, { gatewayVersion: "9.0.0", gatewayBuildId: "build9" });
    const stageRun = await runCli(["stage", "--runtime-root", runtimeRoot, "--seed", seed]);
    assert.equal(stageRun.code, 0);
    const stageBody = JSON.parse(stageRun.stdout.trim());
    assert.equal(stageBody.ok, true);

    const activateRun = await runCli(["activate", "--runtime-root", runtimeRoot, "--version", stageBody.versionId]);
    assert.equal(activateRun.code, 0);
    const activateBody = JSON.parse(activateRun.stdout.trim());
    assert.equal(activateBody.ok, true);
    assert.equal(activateBody.activated.gatewayBuildId, "build9");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("concurrent runtime mutations serialize on the runtime-root lock", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-updater-lock-"));
  try {
    const seed = join(workspace, "seed");
    await writeSmokeCapableSeed(seed);
    const runtimeRoot = join(workspace, "runtime");

    // Two stages of the same seed launched together: exactly one may mutate;
    // the loser must get the stable busy code, not a half-interleaved
    // rm/rename failure (ENOTEMPTY) or a corrupted versions/ entry.
    const [first, second] = await Promise.all([
      stageRuntimeCandidate({ runtimeRoot, seedRoot: seed }),
      stageRuntimeCandidate({ runtimeRoot, seedRoot: seed })
    ]);
    const results = [first, second];
    const winners = results.filter((result) => result.ok);
    const losers = results.filter((result) => !result.ok);
    assert.equal(winners.length, 1, "exactly one concurrent stage wins");
    assert.equal(losers.length, 1);
    assert.equal(losers[0].error.code, "UPDATER_BUSY", "the loser reports the stable busy code");

    // The winner's output is intact and usable.
    const validated = await validateRuntimeCandidate({ runtimeRoot, versionId: winners[0].versionId });
    assert.equal(validated.ok, true, "the surviving stage passes full validation");

    // A stale lock from a dead holder must not wedge the updater forever.
    const staleLock = join(runtimeRoot, ".runtime-mutation.lock");
    await mkdir(staleLock, { recursive: true });
    const past = new Date(Date.now() - 60 * 60 * 1000);
    const { utimes } = await import("node:fs/promises");
    await utimes(staleLock, past, past);
    const reclaimed = await stageRuntimeCandidate({ runtimeRoot, seedRoot: seed });
    assert.equal(reclaimed.ok, true, "a stale lock is reclaimed instead of blocking");
    assert.equal(reclaimed.alreadyStaged, true);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});
