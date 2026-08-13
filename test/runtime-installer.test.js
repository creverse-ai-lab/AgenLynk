import assert from "node:assert/strict";
import { lstat, mkdtemp, readFile, readlink, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { ensureRuntimeInstalled, readCurrentRuntime } from "../src/runtime-installer.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function seed(root, options = {}, generatedAt = "2026-01-01T00:00:00.000Z") {
  await writeRuntimeSeed(root, options);
  const manifest = { ...await buildRuntimeManifest(root), generatedAt };
  await writeFile(join(root, "runtime-manifest.json"), JSON.stringify(manifest));
  return manifest;
}

test("installer copies the composite seed outside the app and activates a stable current link", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const source = join(workspace, "Lynk.app/Contents/Resources/gateway-seed");
    await seed(source);
    const runtimeRoot = join(workspace, "runtime");
    const installed = await ensureRuntimeInstalled({ seedRoot: source, runtimeRoot, smokeCheck: async () => ({}) });
    assert.ok(!installed.runtimeRoot.includes(".app"));
    await assert.doesNotReject(readFile(join(installed.runtimeRoot, "gateway/gateway-client/index.js")));
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(installed.runtimeRoot));
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, installed.runtimeBuildId);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("newer valid seed atomically moves current while an invalid seed leaves it unchanged", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const firstSeed = join(workspace, "seed-a");
    const secondSeed = join(workspace, "seed-b");
    await seed(firstSeed, { marker: "a" }, "2026-01-01T00:00:00.000Z");
    await seed(secondSeed, { marker: "b" }, "2026-02-01T00:00:00.000Z");
    const first = await ensureRuntimeInstalled({ seedRoot: firstSeed, runtimeRoot, smokeCheck: async () => ({}) });
    const second = await ensureRuntimeInstalled({
      seedRoot: secondSeed,
      runtimeRoot,
      smokeCheck: async () => ({}),
      blockers: []
    });
    assert.notEqual(second.runtimeBuildId, first.runtimeBuildId);
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(second.runtimeRoot));

    const invalid = join(workspace, "seed-invalid");
    await seed(invalid, { marker: "invalid" }, "2026-03-01T00:00:00.000Z");
    await writeFile(join(invalid, "gateway/src/index.js"), "tampered\n");
    await assert.rejects(() => ensureRuntimeInstalled({
      seedRoot: invalid,
      runtimeRoot,
      smokeCheck: async () => ({}),
      blockers: []
    }), /validation/);
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, second.runtimeBuildId);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("installer is idempotent for an already verified runtime", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const source = join(workspace, "seed");
    const runtimeRoot = join(workspace, "runtime");
    await seed(source);
    const first = await ensureRuntimeInstalled({ seedRoot: source, runtimeRoot, smokeCheck: async () => ({}) });
    const second = await ensureRuntimeInstalled({ seedRoot: source, runtimeRoot, smokeCheck: async () => ({}) });
    assert.equal(second.runtimeRoot, first.runtimeRoot);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("readCurrentRuntime returns null before first install", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try { assert.equal(await readCurrentRuntime(join(workspace, "runtime")), null); }
  finally { await rm(workspace, { recursive: true, force: true }); }
});

test("first install still activates when active-work state is unknown", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const source = join(workspace, "seed");
    const runtimeRoot = join(workspace, "runtime");
    await seed(source);
    const installed = await ensureRuntimeInstalled({ seedRoot: source, runtimeRoot, smokeCheck: async () => ({}) });
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(installed.runtimeRoot));
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, installed.runtimeBuildId);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("superseding seed does not move current when active work is present or unknown", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const firstSeed = join(workspace, "seed-a");
    await seed(firstSeed, { marker: "a" }, "2026-01-01T00:00:00.000Z");
    const first = await ensureRuntimeInstalled({ seedRoot: firstSeed, runtimeRoot, smokeCheck: async () => ({}) });
    const currentBefore = await readlink(join(runtimeRoot, "current"));

    for (const [label, blockers] of [
      ["activeSessions", { activeSessions: 1 }],
      ["activeTasks", { activeTasks: 1 }],
      ["pendingInbox", { pendingInbox: 1 }],
      ["unknown", undefined],
      ["unknown-null", null]
    ]) {
      const nextSeed = join(workspace, `seed-${label}`);
      await seed(nextSeed, { marker: label }, "2026-06-01T00:00:00.000Z");
      const options = {
        seedRoot: nextSeed,
        runtimeRoot,
        smokeCheck: async () => ({})
      };
      if (blockers !== undefined) options.blockers = blockers;
      const result = await ensureRuntimeInstalled(options);
      assert.equal(result.runtimeBuildId, first.runtimeBuildId, `${label} must keep the active runtime`);
      assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, first.runtimeBuildId, `${label} must leave current.json unchanged`);
      assert.equal(await readlink(join(runtimeRoot, "current")), currentBefore, `${label} must leave the current symlink unchanged`);
      assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(first.runtimeRoot));
    }
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("explicit empty blockers still allow a superseding seed to activate", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const firstSeed = join(workspace, "seed-a");
    const secondSeed = join(workspace, "seed-b");
    await seed(firstSeed, { marker: "a" }, "2026-01-01T00:00:00.000Z");
    await seed(secondSeed, { marker: "b" }, "2026-02-01T00:00:00.000Z");
    const first = await ensureRuntimeInstalled({ seedRoot: firstSeed, runtimeRoot, smokeCheck: async () => ({}) });
    const second = await ensureRuntimeInstalled({
      seedRoot: secondSeed,
      runtimeRoot,
      smokeCheck: async () => ({}),
      blockers: { activeSessions: 0, activeTasks: 0, pendingInbox: 0 }
    });
    assert.notEqual(second.runtimeBuildId, first.runtimeBuildId);
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(second.runtimeRoot));
    assert.ok((await lstat(join(runtimeRoot, "current"))).isSymbolicLink());
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
