import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest, verifyRuntimeManifest } from "../src/runtime-manifest.js";

async function writeFixtureSeed(root, { gatewayVersion = "1.3.1", gatewayBuildId = "abc123", nodeVersion = "22.14.0" } = {}) {
  await mkdir(join(root, "src"), { recursive: true });
  await mkdir(join(root, "skills/agent-delegator"), { recursive: true });
  await mkdir(join(root, "node_modules/@agentclientprotocol/claude-agent-acp"), { recursive: true });
  await mkdir(join(root, "node_modules/@modelcontextprotocol/sdk"), { recursive: true });
  await mkdir(join(root, "node/bin"), { recursive: true });

  await writeFile(join(root, "package.json"), JSON.stringify({ type: "module" }));
  await writeFile(join(root, "package-lock.json"), "{}\n");
  await writeFile(
    join(root, "src/version.js"),
    `export const GATEWAY_VERSION = ${JSON.stringify(gatewayVersion)};\nexport const GATEWAY_BUILD_ID = ${JSON.stringify(gatewayBuildId)};\n`
  );
  for (const name of ["index.js", "guide.js", "bootstrap.js", "monitor.js", "installer.js"]) {
    await writeFile(join(root, "src", name), "export default {};\n");
  }
  await writeFile(join(root, "skills/agent-delegator/SKILL.md"), "# fixture skill\n");
  await writeFile(join(root, "node_modules/@agentclientprotocol/claude-agent-acp/package.json"), "{}\n");
  await writeFile(join(root, "node_modules/@modelcontextprotocol/sdk/package.json"), "{}\n");

  for (const [name, output] of [["node", `v${nodeVersion}`], ["npm", "10.9.0"], ["npx", "10.9.0"]]) {
    const path = join(root, "node/bin", name);
    await writeFile(path, `#!/bin/sh\necho "${output}"\n`);
    await chmod(path, 0o755);
  }
}

test("buildRuntimeManifest captures gatewayVersion/gatewayBuildId/nodeVersion from the seed's own files", async () => {
  const seed = await mkdtemp(join(tmpdir(), "acp-runtime-manifest-"));
  try {
    await writeFixtureSeed(seed, { gatewayVersion: "9.9.9", gatewayBuildId: "deadbeef", nodeVersion: "22.14.0" });
    const manifest = await buildRuntimeManifest(seed);
    assert.equal(manifest.formatVersion, 1);
    assert.equal(manifest.gatewayVersion, "9.9.9");
    assert.equal(manifest.gatewayBuildId, "deadbeef");
    assert.equal(manifest.nodeVersion, "22.14.0");
    await verifyRuntimeManifest(seed, manifest);
  } finally {
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
