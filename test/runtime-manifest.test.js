import assert from "node:assert/strict";
import { chmod, mkdtemp, readFile, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import {
  LEGACY_TARBALL_MANIFEST_FORMAT_VERSION,
  RUNTIME_MANIFEST_FORMAT_VERSION,
  buildRuntimeManifest,
  verifyRuntimeManifest
} from "../src/runtime-manifest.js";
import { GATEWAY_PACKAGE_PATH, OFFICIAL_CLAUDE_HELPER_PATH, writeRuntimeSeed } from "./fixtures/runtime-seed.js";

async function withRoot(run) {
  const root = await mkdtemp(join(tmpdir(), "agenlynk-manifest-"));
  try { await run(root); } finally { await rm(root, { recursive: true, force: true }); }
}

test("composite manifest pins the npm Gateway package independently from app sidecar", () => withRoot(async (root) => {
  const { commit, gatewayBuildId, integrity } = await writeRuntimeSeed(root);
  const manifest = await buildRuntimeManifest(root);
  assert.equal(manifest.formatVersion, RUNTIME_MANIFEST_FORMAT_VERSION);
  assert.equal(manifest.gatewayVersion, "1.8.0");
  // The digest the daemon reports as setup.gatewayBuildId, not the commit.
  assert.equal(manifest.gatewayBuildId, gatewayBuildId);
  assert.match(manifest.gatewayBuildId, /^[a-f0-9]{64}$/);
  assert.equal(manifest.gatewaySourceCommit, commit);
  assert.equal(manifest.gatewayPackage, "acp-gateway-daemon");
  assert.equal(manifest.gatewayIntegrity, integrity);
  assert.equal(manifest.gatewayApiVersion, 1);
  assert.match(manifest.runtimeBuildId, /^[a-f0-9]{16}$/);
  assert.equal(manifest.sidecarVersion, undefined);
  assert.ok(manifest.payload.some((entry) => entry.path === `${GATEWAY_PACKAGE_PATH}/gateway-client/index.js`));
  assert.deepEqual(manifest.payload.find((entry) => entry.path === "gateway"), {
    path: "gateway",
    type: "symlink",
    target: GATEWAY_PACKAGE_PATH,
    sha256: manifest.payload.find((entry) => entry.path === "gateway").sha256
  });
  assert.ok(!manifest.payload.some((entry) => entry.path.startsWith("sidecar/")));
  await assert.doesNotReject(verifyRuntimeManifest(root, manifest));
}));

test("verification rejects a lock that no longer matches the package record", () => withRoot(async (root) => {
  await writeRuntimeSeed(root);
  const manifest = await buildRuntimeManifest(root);
  const lockPath = join(root, "gateway.lock.json");
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  lock.package.integrity = `sha512-${Buffer.alloc(64, 1).toString("base64")}`;
  await writeFile(lockPath, JSON.stringify(lock));
  await assert.rejects(() => verifyRuntimeManifest(root, manifest), /does not match gateway\.lock/);
}));

test("verification rejects modified, missing, and unexpected package files", async () => {
  for (const mutation of ["modified", "missing", "unexpected"]) {
    await withRoot(async (root) => {
      await writeRuntimeSeed(root);
      const manifest = await buildRuntimeManifest(root);
      if (mutation === "modified") await writeFile(join(root, GATEWAY_PACKAGE_PATH, "src/index.js"), "tampered\n");
      if (mutation === "missing") await rm(join(root, GATEWAY_PACKAGE_PATH, "src/bootstrap.js"));
      if (mutation === "unexpected") await writeFile(join(root, GATEWAY_PACKAGE_PATH, "extra.js"), "extra\n");
      await assert.rejects(() => verifyRuntimeManifest(root, manifest), /missing a required file|payload does not match|unexpected entry|missing an entry|checksum mismatch/);
    });
  }
});

test("the gateway alias must stay the relative link into the npm package", async () => {
  for (const mutation of ["copied", "retargeted"]) {
    await withRoot(async (root) => {
      await writeRuntimeSeed(root);
      const manifest = await buildRuntimeManifest(root);
      await unlink(join(root, "gateway"));
      if (mutation === "copied") await symlink(join(root, GATEWAY_PACKAGE_PATH), join(root, "gateway"));
      else await symlink("node_modules", join(root, "gateway"));
      await assert.rejects(() => verifyRuntimeManifest(root, manifest), /must be a symlink to node_modules\/acp-gateway-daemon|missing a required file/);
    });
  }
});

test("an unverified provenance record is never sealed or accepted", () => withRoot(async (root) => {
  await writeRuntimeSeed(root, { provenanceVerified: false });
  await assert.rejects(() => buildRuntimeManifest(root), /provenance was not verified/);
}));

test("the bundled Node must be the version the lock pins", () => withRoot(async (root) => {
  await writeRuntimeSeed(root, { nodeVersion: "22.14.0" });
  const lockPath = join(root, "gateway.lock.json");
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  lock.node.version = "22.23.2";
  lock.node.distribution = "https://nodejs.org/download/release/v22.23.2/node-v22.23.2-darwin-arm64.tar.xz";
  await writeFile(lockPath, JSON.stringify(lock));
  await assert.rejects(() => buildRuntimeManifest(root), /is not the Node 22\.23\.2 gateway\.lock\.json pins/);
}));

test("verification rejects a Node version changed after manifest creation", () => withRoot(async (root) => {
  await writeRuntimeSeed(root);
  const manifest = await buildRuntimeManifest(root);
  await writeFile(join(root, "node/bin/node"), '#!/bin/sh\necho "v23.0.0"\n');
  await chmod(join(root, "node/bin/node"), 0o755);
  await assert.rejects(() => verifyRuntimeManifest(root, manifest), /Node version mismatch/);
}));

test("manifest refuses symlinks that escape the composite runtime", () => withRoot(async (root) => {
  await writeRuntimeSeed(root);
  await symlink("../../../../etc/passwd", join(root, "escape"));
  await assert.rejects(() => buildRuntimeManifest(root), /symlink escapes/);
}));

test("verification rejects a bad package inventory sha256", () => withRoot(async (root) => {
  await writeRuntimeSeed(root);
  const recordPath = join(root, "gateway-package.json");
  const record = JSON.parse(await readFile(recordPath, "utf8"));
  record.files.find((entry) => entry.path === "package.json").sha256 = "a".repeat(64);
  await writeFile(recordPath, `${JSON.stringify(record)}\n`);
  await assert.rejects(() => buildRuntimeManifest(root), /official Gateway file checksum mismatch/);
}));

// ---- format 4: an installed Gateway <= 1.6 runtime tarball ----

test("a legacy runtime tarball install still builds and verifies as format 4", () => withRoot(async (root) => {
  const { commit } = await writeRuntimeSeed(root, { layout: "tarball" });
  const manifest = await buildRuntimeManifest(root);
  assert.equal(manifest.formatVersion, LEGACY_TARBALL_MANIFEST_FORMAT_VERSION);
  assert.equal(manifest.gatewayVersion, "1.6.0");
  assert.equal(manifest.gatewayBuildId, commit);
  await assert.doesNotReject(verifyRuntimeManifest(root, manifest));
  await writeFile(join(root, "gateway/src/index.js"), "tampered\n");
  await assert.rejects(() => verifyRuntimeManifest(root, manifest), /checksum mismatch|payload does not match/);
}));

test("legacy verification rejects lock/artifact-manifest identity mismatch", () => withRoot(async (root) => {
  await writeRuntimeSeed(root, { layout: "tarball" });
  const manifest = await buildRuntimeManifest(root);
  const lockPath = join(root, "gateway.lock.json");
  const lock = JSON.parse(await readFile(lockPath, "utf8"));
  lock.sourceCommit = "f".repeat(40);
  await writeFile(lockPath, JSON.stringify(lock));
  await assert.rejects(() => verifyRuntimeManifest(root, manifest), /does not match gateway\.lock/);
}));

test("legacy verification accepts only a recorded codesign-only transform for the official helper", () => withRoot(async (root) => {
  const { officialHelperSha256 } = await writeRuntimeSeed(root, { layout: "tarball", includeOfficialHelper: true });
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
}));

test("legacy verification rejects an unofficial codesign transform path", () => withRoot(async (root) => {
  await writeRuntimeSeed(root, { layout: "tarball" });
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
}));
