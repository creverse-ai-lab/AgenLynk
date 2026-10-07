import assert from "node:assert/strict";
import { lstat, mkdtemp, readFile, readlink, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { ensureRuntimeInstalled, readCurrentRuntime } from "../src/runtime-installer.js";
import { isPackedSeed, SEED_PAYLOAD_FILE } from "../src/runtime-staging.js";
import { stageRuntimeCandidate } from "../src/runtime-updater.js";
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

test("malformed current.json recovers the verified active symlink without switching during active work", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const firstSeed = join(workspace, "seed-a");
    const newerSeed = join(workspace, "seed-b");
    await seed(firstSeed, { marker: "a" }, "2026-01-01T00:00:00.000Z");
    await seed(newerSeed, { marker: "b" }, "2026-02-01T00:00:00.000Z");
    const first = await ensureRuntimeInstalled({ seedRoot: firstSeed, runtimeRoot, smokeCheck: async () => ({}) });
    await writeFile(join(runtimeRoot, "current.json"), "{malformed\n");

    const recovered = await ensureRuntimeInstalled({
      seedRoot: newerSeed,
      runtimeRoot,
      smokeCheck: async () => ({}),
      blockers: { activeSessions: 1 }
    });

    assert.equal(recovered.runtimeBuildId, first.runtimeBuildId);
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, first.runtimeBuildId);
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(first.runtimeRoot));
    assert.match(recovered.recoveryNotice, /안전 복구/);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("invalid active runtime fails closed when active-work state is unknown", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const firstSeed = join(workspace, "seed-a");
    const repairSeed = join(workspace, "seed-b");
    await seed(firstSeed, { marker: "a" }, "2026-01-01T00:00:00.000Z");
    await seed(repairSeed, { marker: "b" }, "2026-02-01T00:00:00.000Z");
    const first = await ensureRuntimeInstalled({ seedRoot: firstSeed, runtimeRoot, smokeCheck: async () => ({}) });
    await writeFile(join(first.runtimeRoot, "gateway/src/index.js"), "tampered\n");

    await assert.rejects(
      ensureRuntimeInstalled({ seedRoot: repairSeed, runtimeRoot, smokeCheck: async () => ({}) }),
      /활성화를 보류/
    );
    assert.equal((await readCurrentRuntime(runtimeRoot)).runtimeBuildId, first.runtimeBuildId);
    assert.equal(await realpath(join(runtimeRoot, "current")), await realpath(first.runtimeRoot));
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("app launch upgrades an installed 1.6 runtime tarball to the npm package seed", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const legacySeed = join(workspace, "seed-1.6.0");
    const npmSeed = join(workspace, "seed-1.7.2");
    await seed(legacySeed, { layout: "tarball", marker: "legacy" }, "2026-01-01T00:00:00.000Z");
    const npmManifest = await seed(npmSeed, { marker: "npm" }, "2026-09-01T00:00:00.000Z");
    const legacy = await ensureRuntimeInstalled({ seedRoot: legacySeed, runtimeRoot, smokeCheck: async () => ({}) });
    assert.equal(legacy.gatewayVersion, "1.6.0");

    // The installed format 4 runtime still verifies, so it is the upgrade
    // source (and previous.json) rather than a corrupt install to repair.
    const upgraded = await ensureRuntimeInstalled({ seedRoot: npmSeed, runtimeRoot, smokeCheck: async () => ({}), blockers: [] });
    assert.equal(upgraded.gatewayVersion, "1.7.2");
    assert.equal(upgraded.gatewayBuildId, npmManifest.gatewayBuildId);
    assert.equal(upgraded.recoveryNotice, undefined);
    assert.equal(JSON.parse(await readFile(join(runtimeRoot, "previous.json"), "utf8")).gatewayVersion, "1.6.0");
    assert.equal(await readlink(join(upgraded.runtimeRoot, "gateway")), "node_modules/acp-gateway-daemon");
    assert.match(await readFile(join(runtimeRoot, "current/gateway/src/index.js"), "utf8"), /"npm"/);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

// The distribution build packs these into runtime-payload.tar.xz (build-app.sh).
async function pack(root, entries = ["node_modules", "gateway", "node/bin/npm", "node/bin/npx"]) {
  const { execFileSync } = await import("node:child_process");
  // macOS's bsdtar flags; CI's Linux runs GNU tar, which has neither.
  const macOnly = process.platform === "darwin" ? ["--no-xattrs", "--no-mac-metadata"] : [];
  execFileSync("tar", [...macOnly, "-cJf", SEED_PAYLOAD_FILE, ...entries],
    { cwd: root, env: { ...process.env, COPYFILE_DISABLE: "1" } });
  for (const entry of entries) await rm(join(root, entry), { recursive: true, force: true });
}

test("a packed seed is unpacked, verified and activated like a plain one", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-packed-"));
  try {
    const source = join(workspace, "Lynk.app/Contents/Resources/gateway-seed");
    await seed(source);
    await pack(source);
    assert.equal(await isPackedSeed(source), true);
    const runtimeRoot = join(workspace, "runtime");
    const installed = await ensureRuntimeInstalled({ seedRoot: source, runtimeRoot, smokeCheck: async () => ({}) });
    await assert.doesNotReject(readFile(join(installed.runtimeRoot, "gateway/gateway-client/index.js")));
    assert.equal(await readlink(join(installed.runtimeRoot, "gateway")), "node_modules/acp-gateway-daemon");
    await assert.rejects(lstat(join(installed.runtimeRoot, SEED_PAYLOAD_FILE)), "the archive itself is not installed");

    const staged = await stageRuntimeCandidate({ runtimeRoot: join(workspace, "update-root"), seedRoot: source });
    assert.equal(staged.ok, true, JSON.stringify(staged.error));
  } finally { await rm(workspace, { recursive: true, force: true }); }
});

test("a packed seed whose archive holds anything else is refused", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-packed-bad-"));
  try {
    const source = join(workspace, "gateway-seed");
    await seed(source);
    await writeFile(join(source, "node_modules/stowaway.js"), "process.exit(0);\n");
    await pack(source);
    await assert.rejects(ensureRuntimeInstalled({ seedRoot: source, runtimeRoot: join(workspace, "runtime"), smokeCheck: async () => ({}) }));
    assert.equal(await readCurrentRuntime(join(workspace, "runtime")), null);
  } finally { await rm(workspace, { recursive: true, force: true }); }
});
