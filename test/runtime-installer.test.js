import assert from "node:assert/strict";
import { mkdir, mkdtemp, readdir, readFile, readlink, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { activateCurrent, ensureRuntimeInstalled, readCurrentRuntime } from "../src/runtime-installer.js";
import { readPreviousRuntime } from "../src/runtime-updater.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function writeFixtureSeed(root, { generatedAt, ...options } = {}) {
  await writeRuntimeSeed(root, options);
  // generatedAt orders seed against install, and real builds are minutes or
  // days apart; a test writing two seeds in the same millisecond has to say
  // which is newer explicitly.
  const manifest = { ...await buildRuntimeManifest(root), ...(generatedAt ? { generatedAt } : {}) };
  await writeFile(join(root, "runtime-manifest.json"), JSON.stringify(manifest));
  return manifest;
}

test("ensureRuntimeInstalled activates a runtime root outside the seed's .app bundle path", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    // Simulate a real macOS bundle seed path to prove installed resolution
    // escapes it rather than pointing back inside Lynk.app.
    const seed = join(workspace, "Lynk.app", "Contents", "Resources", "runtime");
    await writeFixtureSeed(seed, { gatewayVersion: "1.0.0", gatewayBuildId: "build1" });
    const runtimeRoot = join(workspace, "home", ".acp-gateway", "runtime");

    const result = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    assert.ok(!result.runtimeRoot.includes(".app"), "installed runtime path must not be under the seed's .app bundle");
    assert.ok(result.runtimeRoot.startsWith(runtimeRoot + "/"));
    assert.equal(result.gatewayVersion, "1.0.0");
    assert.equal(result.gatewayBuildId, "build1");

    const current = await readCurrentRuntime(runtimeRoot);
    assert.equal(current.runtimeRoot, result.runtimeRoot);
    assert.ok(!current.runtimeRoot.includes(".app"));

    // The activated copy must be independently usable: its own required
    // files exist under the installed root, not just the seed.
    await assert.doesNotReject(readFile(join(result.runtimeRoot, "sidecar/src/server/monitor.js")));
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled preserves confined relative symlinks from the signed seed", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const seed = join(workspace, "seed");
    await writeFixtureSeed(seed, { gatewayVersion: "1.1.0", gatewayBuildId: "symlink-build" });
    await writeFile(join(seed, "node/npm-cli.js"), "// fixture npm entry\n");
    await symlink("../npm-cli.js", join(seed, "node/bin/npm-link"));
    const manifest = await buildRuntimeManifest(seed);
    await writeFile(join(seed, "runtime-manifest.json"), JSON.stringify(manifest));

    const installed = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot: join(workspace, "runtime") });
    assert.equal(await readlink(join(installed.runtimeRoot, "node/bin/npm-link")), "../npm-cli.js");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled is idempotent: a second run does not re-copy or create a duplicate version", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const seed = join(workspace, "seed");
    await writeFixtureSeed(seed, { gatewayVersion: "2.0.0", gatewayBuildId: "build2" });
    const runtimeRoot = join(workspace, "runtime");

    const first = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    const marker = join(first.runtimeRoot, "src/index.js");
    const beforeStat = await stat(marker);

    const second = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    assert.equal(second.runtimeRoot, first.runtimeRoot);

    const versionDirs = await readdir(join(runtimeRoot, "versions"));
    assert.deepEqual(versionDirs, ["2.0.0-build2-fixture-sidecar"]);

    const afterStat = await stat(marker);
    assert.equal(afterStat.mtimeMs, beforeStat.mtimeMs, "an already-valid installed runtime must not be re-copied");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("sidecar-only build changes install under a distinct version id", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const seedA = join(workspace, "seed-a");
    const seedB = join(workspace, "seed-b");
    await writeFixtureSeed(seedA, {
      gatewayVersion: "1.0.0",
      gatewayBuildId: "same-gw",
      sidecarBuildId: "sidecar-a",
      generatedAt: "2026-01-01T00:00:00.000Z"
    });
    await writeFixtureSeed(seedB, {
      gatewayVersion: "1.0.0",
      gatewayBuildId: "same-gw",
      sidecarBuildId: "sidecar-b",
      generatedAt: "2026-02-01T00:00:00.000Z"
    });

    const first = await ensureRuntimeInstalled({ seedRoot: seedA, runtimeRoot, smokeCheck: async () => {} });
    const second = await ensureRuntimeInstalled({ seedRoot: seedB, runtimeRoot, smokeCheck: async () => {} });

    assert.notEqual(first.runtimeRoot, second.runtimeRoot);
    assert.equal(first.sidecarBuildId, "sidecar-a");
    assert.equal(second.sidecarBuildId, "sidecar-b");
    assert.deepEqual(
      (await readdir(join(runtimeRoot, "versions"))).sort(),
      ["1.0.0-same-gw-sidecar-a", "1.0.0-same-gw-sidecar-b"]
    );
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled leaves current.json as valid JSON with no stray temp files across repeated activation", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const seed = join(workspace, "seed");
    await writeFixtureSeed(seed, { gatewayVersion: "3.0.0", gatewayBuildId: "build3" });
    const runtimeRoot = join(workspace, "runtime");

    for (let attempt = 0; attempt < 3; attempt += 1) {
      await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    }

    const entries = await readdir(runtimeRoot);
    assert.deepEqual(entries.sort(), ["current.json", "staging", "versions"]);
    const stagingEntries = await readdir(join(runtimeRoot, "staging"));
    assert.deepEqual(stagingEntries, [], "staging must not accumulate leftovers after successful activation");

    const raw = await readFile(join(runtimeRoot, "current.json"), "utf8");
    const parsed = JSON.parse(raw);
    assert.equal(parsed.formatVersion, 1);
    assert.equal(parsed.gatewayVersion, "3.0.0");
    assert.equal(parsed.sidecarVersion, "0.4.0");
    assert.equal(parsed.sidecarBuildId, "fixture-sidecar");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled re-stages when the installed copy has been corrupted", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const seed = join(workspace, "seed");
    await writeFixtureSeed(seed, { gatewayVersion: "4.0.0", gatewayBuildId: "build4" });
    const runtimeRoot = join(workspace, "runtime");

    const first = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    await rm(join(first.runtimeRoot, "sidecar/src/server/monitor.js"));

    const second = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    assert.equal(second.runtimeRoot, first.runtimeRoot);
    await assert.doesNotReject(readFile(join(second.runtimeRoot, "sidecar/src/server/monitor.js")));
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("readCurrentRuntime returns null instead of throwing when nothing is installed yet", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    assert.equal(await readCurrentRuntime(join(workspace, "runtime")), null);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

// The app and the runtime it ships with move together, but only forward.
// Reinstalling an older DMG once must not roll the machine back; a machine
// that had an older Lynk installed must not keep running that old runtime
// forever, which is exactly what happened when the seed was never read.
test("ensureRuntimeInstalled keeps an older seed out and lets a newer one through", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    // A prior app run already installed and activated version 5.
    const seedFive = join(workspace, "seed-5");
    await writeFixtureSeed(seedFive, {
      gatewayVersion: "5.0.0", gatewayBuildId: "build5", generatedAt: "2026-02-01T00:00:00.000Z"
    });
    const installed = await ensureRuntimeInstalled({ seedRoot: seedFive, runtimeRoot });
    const marker = join(installed.runtimeRoot, "src/index.js");
    const beforeStat = await stat(marker);

    // Someone reinstalls an older DMG. Its seed must be ignored entirely.
    const seedFour = join(workspace, "seed-4");
    await writeFixtureSeed(seedFour, {
      gatewayVersion: "4.0.0", gatewayBuildId: "build4", generatedAt: "2026-01-01T00:00:00.000Z"
    });
    const kept = await ensureRuntimeInstalled({ seedRoot: seedFour, runtimeRoot });

    assert.equal(kept.gatewayVersion, "5.0.0", "an older seed must not displace a newer runtime");
    assert.equal(kept.runtimeRoot, installed.runtimeRoot);
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "5.0.0");
    assert.deepEqual(
      (await readdir(join(runtimeRoot, "versions"))).sort(),
      ["5.0.0-build5-fixture-sidecar"],
      "an older seed must not even be staged"
    );
    assert.equal((await stat(marker)).mtimeMs, beforeStat.mtimeMs, "the preserved runtime must not be touched");

    // The app is updated. Its newer seed becomes the active runtime.
    const seedSix = join(workspace, "seed-6");
    await writeFixtureSeed(seedSix, {
      gatewayVersion: "6.0.0", gatewayBuildId: "build6", generatedAt: "2026-03-01T00:00:00.000Z"
    });
    const upgraded = await ensureRuntimeInstalled({ seedRoot: seedSix, runtimeRoot, smokeCheck: async () => {} });

    assert.equal(upgraded.gatewayVersion, "6.0.0", "a newer seed must become current");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "6.0.0");
    assert.deepEqual(
      (await readdir(join(runtimeRoot, "versions"))).sort(),
      ["5.0.0-build5-fixture-sidecar", "6.0.0-build6-fixture-sidecar"],
      "the superseded runtime stays on disk so rollback still has a target"
    );

    // Same seed again is a no-op, not a re-copy.
    const repeat = await ensureRuntimeInstalled({ seedRoot: seedSix, runtimeRoot, smokeCheck: async () => {} });
    assert.equal(repeat.gatewayBuildId, "build6");
    assert.deepEqual((await readdir(join(runtimeRoot, "versions"))).sort(), ["5.0.0-build5-fixture-sidecar", "6.0.0-build6-fixture-sidecar"]);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

// An automatic upgrade is only safe if it carries the same guarantees the
// manual updater does: proof the candidate runs, and a way back.
test("an automatic upgrade smoke-checks the seed and records what it replaced", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const seedOld = join(workspace, "seed-old");
    const seedNew = join(workspace, "seed-new");
    await writeFixtureSeed(seedOld, {
      gatewayVersion: "1.0.0", gatewayBuildId: "old", generatedAt: "2026-01-01T00:00:00.000Z"
    });
    await writeFixtureSeed(seedNew, {
      gatewayVersion: "2.0.0", gatewayBuildId: "new", generatedAt: "2026-02-01T00:00:00.000Z"
    });
    await ensureRuntimeInstalled({ seedRoot: seedOld, runtimeRoot, smokeCheck: async () => {} });

    // A candidate that cannot run is abandoned; the working install stays.
    await assert.rejects(
      ensureRuntimeInstalled({
        seedRoot: seedNew,
        runtimeRoot,
        smokeCheck: async () => { throw new Error("bundled node is not executable"); }
      }),
      /failed its smoke check, keeping 1\.0\.0/
    );
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.0.0");
    assert.equal(await readPreviousRuntime(runtimeRoot), null, "an abandoned upgrade must not record a previous target");

    // A candidate that runs is activated, and the replaced runtime becomes
    // rollback's target.
    await ensureRuntimeInstalled({ seedRoot: seedNew, runtimeRoot, smokeCheck: async () => {} });
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "2.0.0");
    assert.equal((await readPreviousRuntime(runtimeRoot)).gatewayVersion, "1.0.0");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

// Rollback lands on a runtime older than the seed that shipped it, so without
// a pin the next launch would re-apply the build the user just rejected.
test("a pinned runtime is never superseded by a newer seed", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const seedOld = join(workspace, "seed-old");
    const seedNew = join(workspace, "seed-new");
    await writeFixtureSeed(seedOld, {
      gatewayVersion: "1.0.0", gatewayBuildId: "old", generatedAt: "2026-01-01T00:00:00.000Z"
    });
    await writeFixtureSeed(seedNew, {
      gatewayVersion: "2.0.0", gatewayBuildId: "new", generatedAt: "2026-02-01T00:00:00.000Z"
    });
    const old = await ensureRuntimeInstalled({ seedRoot: seedOld, runtimeRoot, smokeCheck: async () => {} });
    await ensureRuntimeInstalled({ seedRoot: seedNew, runtimeRoot, smokeCheck: async () => {} });

    // Stand in for rollback: pin the older runtime the way rollbackRuntime does.
    await activateCurrent(runtimeRoot, old.runtimeRoot, { gatewayVersion: "1.0.0", gatewayBuildId: "old" }, { pinned: true });
    assert.equal((await readCurrentRuntime(runtimeRoot)).pinned, true);

    const afterLaunch = await ensureRuntimeInstalled({ seedRoot: seedNew, runtimeRoot, smokeCheck: async () => {} });
    assert.equal(afterLaunch.gatewayVersion, "1.0.0", "a newer seed must not undo a deliberate rollback");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.0.0");

    // Choosing a version explicitly clears the pin and normal updates resume.
    await activateCurrent(runtimeRoot, old.runtimeRoot, { gatewayVersion: "1.0.0", gatewayBuildId: "old" });
    assert.equal((await readCurrentRuntime(runtimeRoot)).pinned, undefined);
    const resumed = await ensureRuntimeInstalled({ seedRoot: seedNew, runtimeRoot, smokeCheck: async () => {} });
    assert.equal(resumed.gatewayVersion, "2.0.0");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

// An install predating the generatedAt field cannot be ordered against
// anything, and is the exact case a newer app must be able to replace.
test("ensureRuntimeInstalled replaces an install whose manifest predates generatedAt", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");
    const oldSeed = join(workspace, "seed-old");
    await writeFixtureSeed(oldSeed, { gatewayVersion: "1.0.0", gatewayBuildId: "old" });
    const installed = await ensureRuntimeInstalled({ seedRoot: oldSeed, runtimeRoot });

    const manifestPath = join(installed.runtimeRoot, "runtime-manifest.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    delete manifest.generatedAt;
    await writeFile(manifestPath, JSON.stringify(manifest));

    const newSeed = join(workspace, "seed-new");
    await writeFixtureSeed(newSeed, {
      gatewayVersion: "2.0.0", gatewayBuildId: "new", generatedAt: "2026-03-01T00:00:00.000Z"
    });
    const result = await ensureRuntimeInstalled({ seedRoot: newSeed, runtimeRoot, smokeCheck: async () => {} });
    assert.equal(result.gatewayVersion, "2.0.0");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled repairs current.json when it is malformed, pointing outside the runtime, or corrupt", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const seed = join(workspace, "seed");
    await writeFixtureSeed(seed, { gatewayVersion: "7.0.0", gatewayBuildId: "build7" });

    // Malformed current.json (invalid JSON) is treated as absent, not fatal.
    const malformedRoot = join(workspace, "malformed-runtime");
    await mkdir(malformedRoot, { recursive: true });
    await writeFile(join(malformedRoot, "current.json"), "{ not json");
    const malformedResult = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot: malformedRoot });
    assert.equal(malformedResult.gatewayVersion, "7.0.0");
    assert.equal((await readCurrentRuntime(malformedRoot)).gatewayVersion, "7.0.0");

    // current.json recorded metadata that doesn't match what is actually on
    // disk at that path (tampered/corrupt record) is also repaired.
    const corruptRoot = join(workspace, "corrupt-runtime");
    await mkdir(join(corruptRoot, "versions", "7.0.0-build7"), { recursive: true });
    await writeFile(
      join(corruptRoot, "current.json"),
      JSON.stringify({
        formatVersion: 1,
        runtimeRoot: join(corruptRoot, "versions", "7.0.0-build7"),
        gatewayVersion: "7.0.0",
        gatewayBuildId: "build7"
      })
    );
    const corruptResult = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot: corruptRoot });
    assert.equal(corruptResult.gatewayVersion, "7.0.0");
    await assert.doesNotReject(readFile(join(corruptResult.runtimeRoot, "sidecar/src/server/monitor.js")));
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled ignores a current.json pointing outside the managed versions directory (path confinement)", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    // A fully valid, independently-installed runtime that simply lives
    // outside <runtimeRoot>/versions/ — e.g. a symlink, a stray sibling
    // directory, or a path-traversal payload in a tampered current.json.
    const outside = join(runtimeRoot, "outside-versions", "8.0.0-build8");
    const outsideManifest = await writeFixtureSeed(outside, { gatewayVersion: "8.0.0", gatewayBuildId: "build8" });
    await mkdir(runtimeRoot, { recursive: true });
    await writeFile(
      join(runtimeRoot, "current.json"),
      JSON.stringify({
        formatVersion: 1,
        runtimeRoot: outside,
        gatewayVersion: outsideManifest.gatewayVersion,
        gatewayBuildId: outsideManifest.gatewayBuildId
      })
    );

    const seed = join(workspace, "seed-9");
    await writeFixtureSeed(seed, { gatewayVersion: "9.0.0", gatewayBuildId: "build9" });
    const result = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });

    assert.equal(result.gatewayVersion, "9.0.0", "a current runtime outside versions/ must be treated as invalid, not preserved");
    assert.ok(result.runtimeRoot.startsWith(join(runtimeRoot, "versions") + "/"));

    const current = await readCurrentRuntime(runtimeRoot);
    assert.equal(current.gatewayVersion, "9.0.0");
    assert.notEqual(current.runtimeRoot, outside);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("ensureRuntimeInstalled rejects a current.json runtimeRoot that is lexically under versions/ but escapes it via a symlink", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "acp-runtime-installer-"));
  try {
    const runtimeRoot = join(workspace, "runtime");

    // A fully valid, independently-installed runtime living entirely outside
    // runtimeRoot, reached only through a symlink placed inside versions/ —
    // lexically "10.0.0-build10" looks confined, but realpath resolves it
    // to somewhere else entirely.
    const realOutside = join(workspace, "elsewhere", "real-runtime");
    const outsideManifest = await writeFixtureSeed(realOutside, { gatewayVersion: "10.0.0", gatewayBuildId: "build10" });
    await mkdir(join(runtimeRoot, "versions"), { recursive: true });
    const symlinkPath = join(runtimeRoot, "versions", "10.0.0-build10");
    await symlink(realOutside, symlinkPath, "dir");
    await writeFile(
      join(runtimeRoot, "current.json"),
      JSON.stringify({
        formatVersion: 1,
        runtimeRoot: symlinkPath,
        gatewayVersion: outsideManifest.gatewayVersion,
        gatewayBuildId: outsideManifest.gatewayBuildId
      })
    );

    const seed = join(workspace, "seed-11");
    await writeFixtureSeed(seed, { gatewayVersion: "11.0.0", gatewayBuildId: "build11" });
    const result = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });

    assert.equal(result.gatewayVersion, "11.0.0", "a symlink escaping versions/ must not be treated as a valid preserved runtime");
    assert.notEqual(result.runtimeRoot, symlinkPath);

    const current = await readCurrentRuntime(runtimeRoot);
    assert.equal(current.gatewayVersion, "11.0.0");
    assert.notEqual(current.runtimeRoot, symlinkPath);
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});
