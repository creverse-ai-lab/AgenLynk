import assert from "node:assert/strict";
import { chmod, lstat, mkdtemp, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { readCurrentRuntime } from "../src/runtime-installer.js";
import { activateRuntimeCandidate, inspectRuntime, pruneRuntimeVersions, readPreviousRuntime, rollbackRuntime, stageRuntimeCandidate, validateRuntimeCandidate } from "../src/runtime-updater.js";
import { runtimeVersionsInUse } from "../src/runtime-usage.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function smokeSeed(root, marker, options = {}) {
  await writeRuntimeSeed(root, { marker, ...options });
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
    assert.match(staged.versionId, /^1\.8\.0-[a-f0-9]{16}$/);
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
    const z = join(workspace, "z");
    const a = join(workspace, "a");
    const b = join(workspace, "b");
    await smokeSeed(z, "z");
    await smokeSeed(a, "a");
    await smokeSeed(b, "b");
    const stagedZ = await stageRuntimeCandidate({ runtimeRoot, seedRoot: z });
    const stagedA = await stageRuntimeCandidate({ runtimeRoot, seedRoot: a });
    const stagedB = await stageRuntimeCandidate({ runtimeRoot, seedRoot: b });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedZ.versionId });
    await activateRuntimeCandidate({ runtimeRoot, versionId: stagedA.versionId });
    const failed = await activateRuntimeCandidate({
      runtimeRoot,
      versionId: stagedB.versionId,
      smokeCheck: async () => ({}),
      healthCheck: async () => { throw new Error("unhealthy"); }
    });
    assert.equal(failed.error.code, "POST_ACTIVATION_HEALTH_CHECK_FAILED");
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, stagedA.runtimeBuildId);
    assert.equal((await readPreviousRuntime(runtimeRoot)).runtimeBuildId, stagedZ.runtimeBuildId);
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
    const pruned = await pruneRuntimeVersions({ runtimeRoot, usage: new Map() });
    assert.equal(pruned.ok, true);
    assert.deepEqual(pruned.removed.map((item) => item.versionId), [ids[2]]);
    assert.ok(pruned.freedBytes > 0);
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, ids[0].split("-").at(-1));
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

// Settings shows what a cleanup frees before doing it, and never removes a
// version an agent MCP entry or a running process still launches from.
test("prune previews first and keeps versions still in use", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const ids = [];
    for (const marker of ["a", "b", "c", "d"]) {
      const source = join(workspace, marker);
      await smokeSeed(source, marker);
      ids.push((await stageRuntimeCandidate({ runtimeRoot, seedRoot: source })).versionId);
    }
    await activateRuntimeCandidate({ runtimeRoot, versionId: ids[0] });
    await activateRuntimeCandidate({ runtimeRoot, versionId: ids[1] });
    const versionsRoot = join(runtimeRoot, "versions");
    const config = join(workspace, "config.toml");
    await writeFile(config, `[mcp_servers.agent-acp-guide]\nargs = ["${join(versionsRoot, ids[2], "gateway", "src", "guide.js")}"]\n`);
    const usage = await runtimeVersionsInUse(versionsRoot, { configPaths: [config], commands: [] });
    assert.deepEqual([...usage.keys()], [ids[2]]);

    const preview = await pruneRuntimeVersions({ runtimeRoot, dryRun: true, usage });
    assert.equal(preview.dryRun, true);
    assert.deepEqual(preview.removed.map((item) => item.versionId), [ids[3]]);
    assert.deepEqual(preview.inUse, [{ versionId: ids[2], reasons: [`config:${config}`] }]);
    assert.equal((await readdir(versionsRoot)).length, 4, "a preview removes nothing");

    const pruned = await pruneRuntimeVersions({ runtimeRoot, usage });
    assert.deepEqual(pruned.removed.map((item) => item.versionId), [ids[3]]);
    assert.deepEqual((await readdir(versionsRoot)).sort(), [ids[0], ids[1], ids[2]].sort());

    const running = await runtimeVersionsInUse(versionsRoot, {
      configPaths: [], commands: [`/node ${join(versionsRoot, ids[2], "gateway", "src", "guide.js")}`]
    });
    assert.deepEqual(running.get(ids[2]), ["process"]);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("a 1.6 runtime tarball install upgrades to the npm package and rolls back, keeping current/ MCP paths", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-updater-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const legacySeed = join(workspace, "legacy");
    const npmSeed = join(workspace, "npm");
    await smokeSeed(legacySeed, "legacy", { layout: "tarball" });
    await smokeSeed(npmSeed, "npm");
    const legacy = await stageRuntimeCandidate({ runtimeRoot, seedRoot: legacySeed });
    assert.match(legacy.versionId, /^1\.6\.0-/);
    assert.equal((await activateRuntimeCandidate({ runtimeRoot, versionId: legacy.versionId })).ok, true);
    // What an existing agent MCP config launches.
    const controlScript = join(runtimeRoot, "current/gateway/src/index.js");
    const controlNode = join(runtimeRoot, "current/node/bin/node");
    assert.match(await readFile(controlScript, "utf8"), /"legacy"/);

    const next = await stageRuntimeCandidate({ runtimeRoot, seedRoot: npmSeed });
    assert.match(next.versionId, /^1\.8\.0-/);
    // The real smoke check: bundled node resolves acp-gateway-daemon/client from the runtime root.
    const validated = await validateRuntimeCandidate({ runtimeRoot, versionId: next.versionId });
    assert.equal(validated.ok, true, JSON.stringify(validated.error));
    assert.equal((await activateRuntimeCandidate({ runtimeRoot, versionId: next.versionId })).ok, true);
    assert.match(await readFile(controlScript, "utf8"), /"npm"/);
    assert.equal(
      await realpath(controlScript),
      await realpath(join(runtimeRoot, "versions", next.versionId, "node_modules/acp-gateway-daemon/src/index.js"))
    );
    await lstat(controlNode);
    assert.equal((await readPreviousRuntime(runtimeRoot)).gatewayVersion, "1.6.0");

    assert.equal((await rollbackRuntime({ runtimeRoot })).ok, true);
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.6.0");
    assert.match(await readFile(controlScript, "utf8"), /"legacy"/);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
