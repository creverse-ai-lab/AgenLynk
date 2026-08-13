#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = fileURLToPath(new URL("../test/", import.meta.url));
const sidecarTestDirectory = fileURLToPath(new URL("../sidecar/test/", import.meta.url));
const quick = process.argv.includes("--quick");
const forwardedArgs = process.argv.slice(2).filter((argument) => argument !== "--quick");
const slowFiles = new Set([
  "monitor-control.test.js",
  "runtime-installer.test.js",
  "runtime-manifest.test.js",
  "runtime-updater.test.js",
  "socket.test.js"
]);

const rootFiles = (await readdir(testDirectory))
  .filter((name) => name.endsWith(".test.js"))
  .map((name) => ({ name, path: join(testDirectory, name) }));
const sidecarFiles = (await readdir(sidecarTestDirectory))
  .filter((name) => name.endsWith(".test.js"))
  .map((name) => ({ name, path: join(sidecarTestDirectory, name) }));
const allFiles = [...rootFiles, ...sidecarFiles].sort((left, right) => left.path.localeCompare(right.path));
const selectedFiles = allFiles
  .filter(({ name }) => !quick || !slowFiles.has(name))
  .map(({ path }) => path);
const artifacts = await mkdtemp(join(tmpdir(), "acp-gateway-test-artifacts-"));
const publicClientFixture = fileURLToPath(new URL("../test/fixtures/gateway-client/index.js", import.meta.url));

if (quick) {
  process.stdout.write(`Quick suite: ${selectedFiles.length}/${allFiles.length} files; full release gate remains npm test.\n`);
}

try {
  const exitCode = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, ["--test", ...forwardedArgs, ...selectedFiles], {
      stdio: "inherit",
      env: {
        ...process.env,
        ACP_GATEWAY_DISABLE_DYNAMIC_PROVIDERS: "1",
        ACP_GATEWAY_ARTIFACTS: artifacts,
        ACP_GATEWAY_CLIENT_ENTRYPOINT: publicClientFixture,
        ACP_GATEWAY_ACTIVE_ROOT: fileURLToPath(new URL("../test/fixtures/", import.meta.url))
      }
    });
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      if (signal) reject(new Error(`test process ended by ${signal}`));
      else resolve(code ?? 1);
    });
  });
  process.exitCode = exitCode;
} finally {
  await rm(artifacts, { recursive: true, force: true });
}
