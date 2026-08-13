import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { mkdtemp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const cli = new URL("../src/build-release-manifest-cli.js", import.meta.url).pathname;

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "acp-release-manifest-"));
  const runtimeRoot = join(root, "runtime");
  await mkdir(runtimeRoot);
  await writeFile(join(runtimeRoot, "runtime-manifest.json"), JSON.stringify({
    gatewayVersion: "1.3.1",
    gatewayBuildId: "build-id",
    gatewayApiVersion: 1,
    sidecarVersion: "0.4.0",
    sidecarBuildId: "sidecar-build-id",
    nodeVersion: "22.23.2"
  }));
  return { root, runtimeRoot, out: join(root, "Lynk.release.json") };
}

function validArgs(runtimeRoot, out) {
  return [
    cli,
    "--runtime-root", runtimeRoot,
    "--app-name", "Lynk.app",
    "--app-version", "0.1.0",
    "--app-build", "1",
    "--bundle-id", "com.example.lynk",
    "--min-macos", "14.0",
    "--arch", "arm64",
    "--dmg-name", "Lynk.dmg",
    "--dmg-bytes", "12345",
    "--dmg-sha256", "a".repeat(64),
    "--signing-mode", "ad-hoc",
    "--notarized", "false",
    "--stapled", "false",
    "--out", out
  ];
}

test("release manifest CLI writes evidence-backed app, runtime, DMG, and signing fields", async () => {
  const { root, runtimeRoot, out } = await fixture();
  try {
    await execFileAsync(process.execPath, validArgs(runtimeRoot, out));
    const release = JSON.parse(await readFile(out, "utf8"));
    assert.equal(release.app.version, "0.1.0");
    assert.equal(release.dmg.bytes, 12345);
    assert.equal(release.dmg.sha256, "a".repeat(64));
    assert.deepEqual(release.gateway, { version: "1.3.1", buildId: "build-id", apiVersion: 1 });
    assert.deepEqual(release.sidecar, { version: "0.4.0", buildId: "sidecar-build-id" });
    assert.deepEqual(release.signing, { mode: "ad-hoc", identity: null, notarized: false, stapled: false });
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("release manifest CLI rejects ambiguous boolean, checksum, and Developer ID evidence", async () => {
  const { root, runtimeRoot, out } = await fixture();
  try {
    const base = validArgs(runtimeRoot, out);
    const booleanArgs = [...base];
    booleanArgs[booleanArgs.indexOf("--notarized") + 1] = "1";
    await assert.rejects(execFileAsync(process.execPath, booleanArgs), /must be true or false/);

    const checksumArgs = [...base];
    checksumArgs[checksumArgs.indexOf("--dmg-sha256") + 1] = "not-a-digest";
    await assert.rejects(execFileAsync(process.execPath, checksumArgs), /64-character SHA-256/);

    const developerIdArgs = [...base];
    developerIdArgs[developerIdArgs.indexOf("--signing-mode") + 1] = "developer-id";
    await assert.rejects(execFileAsync(process.execPath, developerIdArgs), /signing-identity is required/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
