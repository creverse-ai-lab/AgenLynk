import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { RUNTIME_MANIFEST_FORMAT_VERSION, buildRuntimeManifest, verifyRuntimeManifest } from "../src/runtime-manifest.js";
import { OFFICIAL_CLAUDE_HELPER_PATH, writeRuntimeSeed } from "./fixtures/runtime-seed.js";

test("composite manifest pins Gateway 1.4.0 independently from app sidecar", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    const { commit } = await writeRuntimeSeed(root);
    const manifest = await buildRuntimeManifest(root);
    assert.equal(manifest.formatVersion, RUNTIME_MANIFEST_FORMAT_VERSION);
    assert.equal(manifest.gatewayVersion, "1.4.0");
    assert.equal(manifest.gatewayBuildId, commit);
    assert.equal(manifest.gatewayApiVersion, 1);
    assert.match(manifest.runtimeBuildId, /^[a-f0-9]{16}$/);
    assert.equal(manifest.sidecarVersion, undefined);
    assert.ok(manifest.payload.some((entry) => entry.path === "gateway/gateway-client/index.js"));
    assert.ok(!manifest.payload.some((entry) => entry.path.startsWith("sidecar/")));
    await assert.doesNotReject(verifyRuntimeManifest(root, manifest));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("verification rejects lock/artifact-manifest identity mismatch", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    await writeRuntimeSeed(root);
    const manifest = await buildRuntimeManifest(root);
    const lockPath = join(root, "gateway.lock.json");
    const lock = JSON.parse(await readFile(lockPath, "utf8"));
    lock.sourceCommit = "f".repeat(40);
    await writeFile(lockPath, JSON.stringify(lock));
    await assert.rejects(() => verifyRuntimeManifest(root, manifest), /does not match gateway\.lock/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("verification rejects modified, missing, and unexpected payload files", async () => {
  for (const mutation of ["modified", "missing", "unexpected"]) {
    const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
    try {
      await writeRuntimeSeed(root);
      const manifest = await buildRuntimeManifest(root);
      if (mutation === "modified") await writeFile(join(root, "gateway/src/index.js"), "tampered\n");
      if (mutation === "missing") await rm(join(root, "gateway/src/bootstrap.js"));
      if (mutation === "unexpected") await writeFile(join(root, "gateway/extra.js"), "extra\n");
      await assert.rejects(() => verifyRuntimeManifest(root, manifest), /missing a required file|payload does not match|unexpected entry|checksum mismatch/);
    } finally { await rm(root, { recursive: true, force: true }); }
  }
});

test("verification rejects a Node version changed after manifest creation", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    await writeRuntimeSeed(root);
    const manifest = await buildRuntimeManifest(root);
    await writeFile(join(root, "node/bin/node"), '#!/bin/sh\necho "v23.0.0"\n');
    await chmod(join(root, "node/bin/node"), 0o755);
    await assert.rejects(() => verifyRuntimeManifest(root, manifest), /Node version mismatch/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("manifest refuses symlinks that escape the composite runtime", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    await writeRuntimeSeed(root);
    await symlink("../../../../etc/passwd", join(root, "escape"));
    await assert.rejects(() => buildRuntimeManifest(root), /symlink escapes/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("verification rejects a bad official files[].sha256", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    await writeRuntimeSeed(root);
    const officialPath = join(root, "gateway/runtime-manifest.json");
    const official = JSON.parse(await readFile(officialPath, "utf8"));
    const packageEntry = official.files.find((entry) => entry.path === "package.json");
    packageEntry.sha256 = "a".repeat(64);
    await writeFile(officialPath, `${JSON.stringify(official)}\n`);
    await assert.rejects(() => buildRuntimeManifest(root), /official Gateway file checksum mismatch/);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("verification accepts only a recorded codesign-only transform for the official helper", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    const { officialHelperSha256 } = await writeRuntimeSeed(root, { includeOfficialHelper: true });
    const helper = join(root, "gateway", OFFICIAL_CLAUDE_HELPER_PATH);
    await writeFile(helper, "re-signed-helper\n");
    await assert.rejects(() => buildRuntimeManifest(root), /official Gateway file checksum mismatch/);

    const { createHash } = await import("node:crypto");
    const installedSha256 = createHash("sha256").update("re-signed-helper\n").digest("hex");
    await writeFile(join(root, "official-codesign-transforms.json"), `${JSON.stringify([{
      path: OFFICIAL_CLAUDE_HELPER_PATH,
      kind: "codesign",
      officialSha256: officialHelperSha256,
      installedSha256
    }])}\n`);
    const manifest = await buildRuntimeManifest(root);
    assert.equal(manifest.officialCodesignTransforms[0].kind, "codesign");
    await assert.doesNotReject(verifyRuntimeManifest(root, manifest));
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("verification rejects an unofficial codesign transform path", async () => {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try {
    await writeRuntimeSeed(root);
    const original = await readFile(join(root, "gateway/src/index.js"), "utf8");
    const { createHash } = await import("node:crypto");
    await writeFile(join(root, "gateway/src/index.js"), "mutated\n");
    await writeFile(join(root, "official-codesign-transforms.json"), `${JSON.stringify([{
      path: "src/index.js",
      kind: "codesign",
      officialSha256: createHash("sha256").update(original).digest("hex"),
      installedSha256: createHash("sha256").update("mutated\n").digest("hex")
    }])}\n`);
    await assert.rejects(() => buildRuntimeManifest(root), /official codesign transform path is not allowed/);
  } finally { await rm(root, { recursive: true, force: true }); }
});
