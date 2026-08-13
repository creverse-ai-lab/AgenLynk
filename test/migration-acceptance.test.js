import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { ensureRuntimeInstalled, readCurrentRuntime } from "../src/runtime-installer.js";
import { buildRuntimeManifest, verifyRuntimeManifest } from "../src/runtime-manifest.js";
import { rollbackRuntime } from "../src/runtime-updater.js";
import { writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function seed(root, gatewayVersion, gatewayBuildId, generatedAt) {
  await writeRuntimeSeed(root, { gatewayVersion, gatewayBuildId, marker: gatewayVersion });
  const manifest = { ...await buildRuntimeManifest(root), generatedAt };
  await writeFile(join(root, "runtime-manifest.json"), `${JSON.stringify(manifest)}\n`);
  return manifest;
}

const smokeCheck = async () => ({ ok: true });

test("0.3.5 to 0.4.0 migration matrix preserves user state and supports safe 1.4.0 rollback", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-migration-"));
  try {
    const controlRoot = join(workspace, ".acp-gateway");
    const runtimeRoot = join(controlRoot, "runtime");
    const seed132 = join(workspace, "seed-1.3.2");
    const seed140 = join(workspace, "seed-1.4.0");
    await seed(seed132, "1.3.2", "gateway-132", "2026-01-01T00:00:00.000Z");
    await seed(seed140, "1.4.0", "gateway-140", "2026-08-01T00:00:00.000Z");

    await mkdir(join(controlRoot, "sessions"), { recursive: true });
    const legacyState = new Map([
      [join(controlRoot, "install.json"), '{"version":1,"identity":{"rootId":"legacy-root","token":"legacy-control-token-123456789"}}\n'],
      [join(controlRoot, "settings.json"), '{"petEnabled":true,"theme":"system"}\n'],
      [join(controlRoot, "sessions", "legacy.ndjson"), '{"sessionId":"legacy-session","sequence":1}\n']
    ]);
    for (const [path, contents] of legacyState) await writeFile(path, contents);

    const legacy = await ensureRuntimeInstalled({ seedRoot: seed132, runtimeRoot, smokeCheck });
    assert.equal(legacy.gatewayVersion, "1.3.2");

    const deferred = await ensureRuntimeInstalled({
      seedRoot: seed140,
      runtimeRoot,
      smokeCheck,
      blockers: { activeTasks: 1 }
    });
    assert.equal(deferred.gatewayVersion, "1.3.2", "active work must defer activation");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.3.2");

    const upgraded = await ensureRuntimeInstalled({ seedRoot: seed140, runtimeRoot, smokeCheck, blockers: [] });
    assert.equal(upgraded.gatewayVersion, "1.4.0");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.4.0");
    for (const [path, contents] of legacyState) {
      assert.equal(await readFile(path, "utf8"), contents, `${path} must survive the app/runtime upgrade byte-for-byte`);
    }

    const rollback = await rollbackRuntime({ runtimeRoot, blockers: [], smokeCheck, healthCheck: smokeCheck });
    assert.equal(rollback.ok, true);
    const rolledBack = await readCurrentRuntime(runtimeRoot);
    assert.equal(rolledBack.gatewayVersion, "1.3.2");
    assert.equal(rolledBack.pinned, true, "rollback must pin the known-good runtime against startup re-upgrade");

    const pinnedStartup = await ensureRuntimeInstalled({
      seedRoot: seed140,
      runtimeRoot,
      smokeCheck,
      blockers: []
    });
    assert.equal(pinnedStartup.gatewayVersion, "1.3.2", "next startup with the same 1.4.0 bundled seed must respect the pin and stay on 1.3.2");
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.3.2", "next startup with the same 1.4.0 bundled seed must respect the pin and stay on 1.3.2");
  } finally {
    await rm(workspace, { recursive: true, force: true });
  }
});

test("fresh offline install repairs malformed current.json and refuses a corrupt runtime payload", async () => {
  const workspace = await mkdtemp(join(tmpdir(), "agenlynk-fresh-install-"));
  const originalFetch = globalThis.fetch;
  try {
    const runtimeRoot = join(workspace, "runtime");
    const bundledSeed = join(workspace, "bundled-seed");
    await seed(bundledSeed, "1.4.0", "gateway-140", "2026-08-01T00:00:00.000Z");
    await mkdir(runtimeRoot, { recursive: true });
    await writeFile(join(runtimeRoot, "current.json"), "{malformed-json\n");
    globalThis.fetch = async () => { throw new Error("network must not be used for bundled install"); };

    const installed = await ensureRuntimeInstalled({ seedRoot: bundledSeed, runtimeRoot, smokeCheck });
    assert.equal(installed.gatewayVersion, "1.4.0");
    assert.match(installed.recoveryNotice, /current\.json.*복구/);
    assert.equal((await readCurrentRuntime(runtimeRoot)).gatewayVersion, "1.4.0");

    await writeFile(join(installed.runtimeRoot, "gateway/src/index.js"), "tampered\n");
    const manifest = JSON.parse(await readFile(join(installed.runtimeRoot, "runtime-manifest.json"), "utf8"));
    await assert.rejects(verifyRuntimeManifest(installed.runtimeRoot, manifest), /payload|manifest|modified|checksum mismatch/);
  } finally {
    globalThis.fetch = originalFetch;
    await rm(workspace, { recursive: true, force: true });
  }
});
