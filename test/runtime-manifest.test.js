import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { RUNTIME_MANIFEST_FORMAT_VERSION, buildRuntimeManifest, verifyRuntimeManifest } from "../src/runtime-manifest.js";
import { computeGatewayBuildId } from "../src/version.js";
import { writeRuntimeSeed as writeFixtureSeed } from "./fixtures/runtime-seed.js";

test("buildRuntimeManifest captures gatewayVersion/gatewayBuildId/nodeVersion from the seed's own files", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed, { gatewayVersion: "9.9.9", gatewayBuildId: "deadbeef", nodeVersion: "22.14.0", gatewayApiVersion: 3 });
    const manifest = await buildRuntimeManifest(seed);
    assert.equal(manifest.formatVersion, RUNTIME_MANIFEST_FORMAT_VERSION);
    assert.equal(manifest.gatewayVersion, "9.9.9");
    assert.equal(manifest.gatewayBuildId, "deadbeef");
    assert.equal(manifest.gatewayApiVersion, 3);
    assert.equal(manifest.nodeVersion, "22.14.0");
    assert.ok(Array.isArray(manifest.payload) && manifest.payload.length > 0, "payload inventory should be populated");
    assert.ok(!manifest.payload.some((entry) => entry.path === "runtime-manifest.json"), "the manifest must not describe itself");
    const paths = manifest.payload.map((entry) => entry.path);
    assert.deepEqual(paths, [...paths].sort(), "payload entries must be sorted by path");
    const result = await verifyRuntimeManifest(seed, manifest);
    assert.equal(typeof result.verificationMs, "number");
    assert.ok(result.verificationMs >= 0);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest runs bundled npm and npx when the inherited PATH has no Node", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  const inheritedPath = process.env.PATH;
  try {
    await writeFixtureSeed(seed);
    // Match the official Node distribution: npm/npx locate `node` through
    // /usr/bin/env rather than by an absolute path in their shebang.
    await writeFile(join(seed, "node/bin/npm"), "#!/usr/bin/env node\n");
    await writeFile(join(seed, "node/bin/npx"), "#!/usr/bin/env node\n");
    await chmod(join(seed, "node/bin/npm"), 0o755);
    await chmod(join(seed, "node/bin/npx"), 0o755);
    const manifest = await buildRuntimeManifest(seed);

    process.env.PATH = join(seed, "path-without-node");
    await verifyRuntimeManifest(seed, manifest);
  } finally {
    if (inheritedPath === undefined) delete process.env.PATH;
    else process.env.PATH = inheritedPath;
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects an incomplete copy missing a required file", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    const manifest = await buildRuntimeManifest(seed);
    await rm(join(seed, "src/monitor.js"));
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /missing a required file/);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects a root whose build id does not match the recorded manifest", async () => {
  // Two distinct directories (not the same path mutated in place) so each
  // gets its own fresh dynamic import of src/version.js: Node's ESM loader
  // caches a given file:// URL for the life of the process, so re-importing
  // the *same* path after editing it in place would misleadingly return the
  // stale cached export instead of exercising the mismatch check.
  const original = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  const tampered = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(original, { gatewayVersion: "1.0.0", gatewayBuildId: "original" });
    const manifest = await buildRuntimeManifest(original);
    await writeFixtureSeed(tampered, { gatewayVersion: "1.0.0", gatewayBuildId: "tampered" });
    await assert.rejects(() => verifyRuntimeManifest(tampered, manifest), /does not match its manifest/);
  } finally {
    await rm(original, { recursive: true, force: true });
    await rm(tampered, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects a Node binary whose reported version no longer matches", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed, { nodeVersion: "22.14.0" });
    const manifest = await buildRuntimeManifest(seed);
    await writeFile(join(seed, "node/bin/node"), '#!/bin/sh\necho "v19.0.0"\n');
    await chmod(join(seed, "node/bin/node"), 0o755);
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /Node version mismatch/);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects a Gateway API version that no longer matches", async () => {
  // Two distinct directories, same reasoning as the build-id mismatch test
  // above: dynamic import caches by file:// URL, so tampering the *same*
  // path in place would misleadingly keep returning the cached export.
  const original = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  const tampered = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(original, { gatewayVersion: "1.0.0", gatewayBuildId: "same-build", gatewayApiVersion: 1 });
    const manifest = await buildRuntimeManifest(original);
    await writeFixtureSeed(tampered, { gatewayVersion: "1.0.0", gatewayBuildId: "same-build", gatewayApiVersion: 2 });
    await assert.rejects(() => verifyRuntimeManifest(tampered, manifest), /Gateway API version mismatch/);
  } finally {
    await rm(original, { recursive: true, force: true });
    await rm(tampered, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects an older manifest format that predates the payload inventory", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    const manifest = await buildRuntimeManifest(seed);
    await assert.rejects(
      () => verifyRuntimeManifest(seed, { ...manifest, formatVersion: 1 }),
      /unsupported runtime manifest format/
    );
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest detects a payload file modified after the manifest was built", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    const manifest = await buildRuntimeManifest(seed);
    // Not in REQUIRED_RUNTIME_FILES and not part of gateway identity, so only
    // the payload checksum inventory — not the existing marker/identity
    // checks — can catch this tampering.
    const target = join(seed, "skills/agent-delegator/SKILL.md");
    await writeFile(target, "# tampered\n");
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /modified.*SKILL\.md/s);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest detects a file removed after the manifest was built (missing payload entry)", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    await writeFile(join(seed, "extra.txt"), "not required, but was shipped\n");
    const manifest = await buildRuntimeManifest(seed);
    await rm(join(seed, "extra.txt"));
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /missing.*extra\.txt/s);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest detects a file added after the manifest was built (unexpected payload entry)", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    const manifest = await buildRuntimeManifest(seed);
    await writeFile(join(seed, "src/smuggled.js"), "export default {};\n");
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /unexpected.*smuggled\.js/s);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("buildRuntimeManifest hashes a confined symlink by its target text without following it, and verification catches a retargeted link", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    await symlink("../npm-cli.js", join(seed, "node/bin/npm-link"), "file");
    await writeFile(join(seed, "node/npm-cli.js"), "// npm entry\n");
    const manifest = await buildRuntimeManifest(seed);
    const linkEntry = manifest.payload.find((entry) => entry.path === "node/bin/npm-link");
    assert.ok(linkEntry, "a confined symlink must appear in the payload inventory");
    assert.equal(linkEntry.type, "symlink");
    assert.equal(linkEntry.target, "../npm-cli.js");
    await verifyRuntimeManifest(seed, manifest);

    await rm(join(seed, "node/bin/npm-link"));
    await symlink("../../../../etc/hosts", join(seed, "node/bin/npm-link"), "file");
    await assert.rejects(() => verifyRuntimeManifest(seed, manifest), /escapes its root|modified/);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("buildRuntimeManifest rejects a symlink whose target escapes the runtime root", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    await symlink("../../../../etc/hosts", join(seed, "node/bin/escape-link"), "file");
    await assert.rejects(() => buildRuntimeManifest(seed), /escapes its root/);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("verifyRuntimeManifest rejects a manifest payload with an unsafe declared path", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed);
    const manifest = await buildRuntimeManifest(seed);

    const traversal = { ...manifest, payload: [...manifest.payload, { path: "../outside.txt", type: "file", sha256: "a".repeat(64) }] };
    await assert.rejects(() => verifyRuntimeManifest(seed, traversal), /unsafe path/);

    const absolute = { ...manifest, payload: [...manifest.payload, { path: "/etc/hosts", type: "file", sha256: "a".repeat(64) }] };
    await assert.rejects(() => verifyRuntimeManifest(seed, absolute), /unsafe path/);

    const duplicate = { ...manifest, payload: [...manifest.payload, manifest.payload[0]] };
    await assert.rejects(() => verifyRuntimeManifest(seed, duplicate), /duplicate path/);
  } finally {
    await rm(seed, { recursive: true, force: true });
  }
});

test("gatewayBuildId covers nested payload files, not just top-level src scripts", async () => {
  const root = await mkdtemp(join(tmpdir(), "acp-build-id-"));
  try {
    await mkdir(join(root, "src", "local-agents"), { recursive: true });
    await writeFile(join(root, "package.json"), JSON.stringify({ name: "acp-gateway", version: "1.3.1" }));
    await writeFile(join(root, "src", "version.js"), "export const GATEWAY_VERSION = \"1.3.1\";\n");
    await writeFile(join(root, "src", "local-agents", "nested.js"), "# original\n");
    const original = computeGatewayBuildId(root);

    // The regression this guards: a nested payload file changed while the id
    // stayed put, so an already-installed runtime looked current even though
    // the app had just shipped different files.
    await writeFile(join(root, "src", "local-agents", "nested.js"), "# changed\n");
    assert.notEqual(computeGatewayBuildId(root), original, "a nested payload change must change the build id");

    await writeFile(join(root, "src", "local-agents", "nested.js"), "# original\n");
    assert.equal(computeGatewayBuildId(root), original, "restoring the payload must restore the build id");

    await mkdir(join(root, "skills", "agent-delegator"), { recursive: true });
    await writeFile(join(root, "skills", "agent-delegator", "SKILL.md"), "# skill\n");
    assert.notEqual(computeGatewayBuildId(root), original, "a shipped skill must be covered by the build id");

    assert.equal(computeGatewayBuildId(root), computeGatewayBuildId(root), "the build id must be deterministic");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
