#!/usr/bin/env node
import { spawn } from "node:child_process";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const testDirectory = fileURLToPath(new URL("../test/", import.meta.url));
const quick = process.argv.includes("--quick");
const forwardedArgs = process.argv.slice(2).filter((argument) => argument !== "--quick");
const slowFiles = new Set([
  "monitor-control.test.js",
  "runtime-installer.test.js",
  "runtime-manifest.test.js",
  "runtime-updater.test.js",
  "socket.test.js"
]);

const allFiles = (await readdir(testDirectory))
  .filter((name) => name.endsWith(".test.js"))
  .sort();
const selectedFiles = allFiles
  .filter((name) => !quick || !slowFiles.has(name))
  .map((name) => join(testDirectory, name));
const artifacts = await mkdtemp(join(tmpdir(), "acp-gateway-test-artifacts-"));

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
        ACP_GATEWAY_ARTIFACTS: artifacts
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
