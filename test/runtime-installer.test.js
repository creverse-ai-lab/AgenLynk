import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { buildRuntimeManifest } from "../src/runtime-manifest.js";
import { ensureRuntimeInstalled, readCurrentRuntime } from "../src/runtime-installer.js";

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

  const manifest = await buildRuntimeManifest(root);
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
    await assert.doesNotReject(readFile(join(result.runtimeRoot, "src/monitor.js")));
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
    assert.deepEqual(versionDirs, ["2.0.0-build2"]);

    const afterStat = await stat(marker);
    assert.equal(afterStat.mtimeMs, beforeStat.mtimeMs, "an already-valid installed runtime must not be re-copied");
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
    await rm(join(first.runtimeRoot, "src/monitor.js"));

    const second = await ensureRuntimeInstalled({ seedRoot: seed, runtimeRoot });
    assert.equal(second.runtimeRoot, first.runtimeRoot);
    await assert.doesNotReject(readFile(join(second.runtimeRoot, "src/monitor.js")));
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
