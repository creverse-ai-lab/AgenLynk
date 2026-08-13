import assert from "node:assert/strict";
import { chmod, lstat, mkdtemp, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { readCurrentRuntime } from "../src/runtime-installer.js";
import { activateRuntimeCandidate, inspectRuntime, pruneRuntimeVersions, rollbackRuntime, stageRuntimeCandidate, validateRuntimeCandidate } from "../src/runtime-updater.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function smokeSeed(root, marker) {
  await writeRuntimeSeed(root, { marker });
  const node = join(root, "node/bin/node");
  await writeFile(node, '#!/bin/sh\nif [ "$1" = "--version" ]; then echo "v22.14.0"; else exec node "$@"; fi\n');
  await chmod(node, 0o755);
  const manifest = await buildRuntimeManifest(root);
  await writeFile(join(root, "runtime-manifest.json"), JSON.stringify(manifest));
  return manifest;
}

test("stage, validate, activate, and inspect use the pinned public client", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const source = join(workspace, "seed");
    const runtimeRoot = join(workspace, "runtime");
    await smokeSeed(source, "a");
    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: source });
    assert.equal(staged.ok, true);
    assert.match(staged.versionId, /^1\.4\.0-[a-f0-9]{16}$/);
    const validated = await validateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId });
    assert.equal(validated.ok, true);
    assert.equal(validated.smoke.gatewayApiVersion, 1);
    assert.equal((await activateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId })).ok, true);
    const inspected = await inspectRuntime({ runtimeRoot, deep: true });
    assert.equal(inspected.versions[0].verified, true);
    assert.equal(inspected.versions[0].isCurrent, true);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("activation and rollback fail closed on sessions, tasks, or inbox blockers", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const source = join(workspace, "seed");
    const runtimeRoot = join(workspace, "runtime");
    await smokeSeed(source, "a");
    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: source });
    for (const blockers of [
      { activeSessions: 1 },
      { activeTasks: 1 },
      { pendingInbox: 1 }
    ]) {
      const activation = await activateRuntimeCandidate({ runtimeRoot, versionId: staged.versionId, blockers });
      assert.equal(activation.error.code, "ACTIVATION_BLOCKED");
      const rollback = await rollbackRuntime({ runtimeRoot, blockers });
      assert.equal(rollback.error.code, "ROLLBACK_BLOCKED");
    }
    assert.equal(await readCurrentRuntime(runtimeRoot), null);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("post-activation failure restores the previous verified target", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const a = join(workspace, "a");
    const b = join(workspace, "b");
    await smokeSeed(a, "a");
    await smokeSeed(b, "b");
    const stagedA = await stageRuntimeCandidate({ runtimeRoot, seedRoot: a });
    const stagedB = await stageRuntimeCandidate({ runtimeRoot, seedRoot: b });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedA.versionId });
    const failed = await activateRuntimeCandidate({
      runtimeRoot,
      versionId: stagedB.versionId,
      smokeCheck: async () => ({}),
      healthCheck: async () => { throw new Error("unhealthy"); }
    });
    assert.equal(failed.error.code, "POST_ACTIVATION_HEALTH_CHECK_FAILED");
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, stagedA.runtimeBuildId);
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(stagedA.runtimeRoot));
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("post-activation health failure with no previous target removes current.json and the current symlink", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const source = join(workspace, "a");
    await smokeSeed(source, "a");
    const staged = await stageRuntimeCandidate({ runtimeRoot, seedRoot: source });
    const failed = await activateRuntimeCandidate({
      runtimeRoot,
      versionId: staged.versionId,
      smokeCheck: async () => ({}),
      healthCheck: async () => { throw new Error("unhealthy"); }
    });
    assert.equal(failed.error.code, "POST_ACTIVATION_HEALTH_CHECK_FAILED");
    assert.equal(failed.error.restoredTo, null);
    assert.equal(await readCurrentRuntime(runtimeRoot), null);
    await assert.rejects(lstat(join(runtimeRoot, "current")), { code: "ENOENT" });
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("post-rollback health failure with no current to restore removes current.json and the current symlink", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const a = join(workspace, "a");
    const b = join(workspace, "b");
    await smokeSeed(a, "a");
    await smokeSeed(b, "b");
    const stagedA = await stageRuntimeCandidate({ runtimeRoot, seedRoot: a });
    const stagedB = await stageRuntimeCandidate({ runtimeRoot, seedRoot: b });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedA.versionId });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedB.versionId });
    await rm(join(runtimeRoot, "current.json"), { force: true });
    const failed = await rollbackRuntime({
      runtimeRoot,
      smokeCheck: async () => ({}),
      healthCheck: async () => { throw new Error("unhealthy"); }
    });
    assert.equal(failed.error.code, "POST_ROLLBACK_HEALTH_CHECK_FAILED");
    assert.equal(failed.error.restoredTo, null);
    assert.equal(await readCurrentRuntime(runtimeRoot), null);
    await assert.rejects(lstat(join(runtimeRoot, "current")), { code: "ENOENT" });
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("rollback restores previous and prune never removes current or previous", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const ids = [];
    for (const marker of ["a", "b", "c"]) {
      const source = join(workspace, marker);
      await smokeSeed(source, marker);
      ids.push((await stageRuntimeCandidate({ runtimeRoot, seedRoot: source })).versionId);
    }
    await activateRuntimeCandidate({ runtimeRoot, versionId: ids[0] });
    await activateRuntimeCandidate({ runtimeRoot, versionId: ids[1] });
    assert.equal((await rollbackRuntime({ runtimeRoot })).ok, true);
    const pruned = await pruneRuntimeVersions({ runtimeRoot });
    assert.equal(pruned.ok, true);
    assert.ok(pruned.removed.includes(ids[2]));
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, ids[0].split("-").at(-1));
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
