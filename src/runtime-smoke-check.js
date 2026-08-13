// Proves a runtime tree can actually run before anything is pointed at it.
//
// Deliberately more than checksum verification, which only proves the bytes on
// disk match the manifest: this executes the candidate's *own bundled* node
// binary (not the host Node running this process) to import its own
// src/version.js, src/gateway-api-version.js, and sidecar/src/version.js,
// and compares what it reports against the manifest. So it also proves the
// bundled runtime can execute JS
// and resolve its own modules. No network access, no shell string, no
// randomness: same target -> same result every time.
//
// Both the manual updater and the app's automatic upgrade gate on this — an
// automatic replacement that skipped it could leave a machine pointed at a
// runtime that cannot start.

import { execFile } from "node:child_process";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

class SmokeCheckError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "SmokeCheckError";
    this.details = details;
  }
}

export async function runBundledRuntimeSmokeCheck(target, manifest) {
  const nodeBinary = join(target, "node", "bin", "node");
  const versionModuleUrl = pathToFileURL(join(target, "src", "version.js")).href;
  const apiModuleUrl = pathToFileURL(join(target, "src", "gateway-api-version.js")).href;
  // Import sidecar/src/version.js only. sidecar/src/server/monitor.js starts
  // the HTTP server on import, so smoke must never load it.
  const sidecarModuleUrl = pathToFileURL(join(target, "sidecar", "src", "version.js")).href;
  const script = `(async () => {
    const [versionUrl, apiUrl, sidecarUrl] = process.argv.slice(1);
    const version = await import(versionUrl);
    const api = await import(apiUrl);
    const sidecar = await import(sidecarUrl);
    process.stdout.write(JSON.stringify({
      gatewayVersion: version.GATEWAY_VERSION,
      gatewayBuildId: version.GATEWAY_BUILD_ID,
      gatewayApiVersion: api.GATEWAY_API_VERSION,
      sidecarVersion: sidecar.SIDECAR_VERSION,
      sidecarBuildId: sidecar.SIDECAR_BUILD_ID
    }));
  })().catch((error) => {
    process.stderr.write(String((error && error.stack) || error));
    process.exit(1);
  });`;

  let stdout;
  try {
    ({ stdout } = await execFileAsync(
      nodeBinary,
      ["-e", script, versionModuleUrl, apiModuleUrl, sidecarModuleUrl],
      { timeout: 10_000 }
    ));
  } catch (error) {
    throw new SmokeCheckError(`bundled runtime smoke check failed to execute: ${error.message}`);
  }

  let reported;
  try {
    reported = JSON.parse(stdout);
  } catch {
    throw new SmokeCheckError("bundled runtime smoke check produced non-JSON output");
  }
  if (
    reported.gatewayVersion !== manifest.gatewayVersion
    || reported.gatewayBuildId !== manifest.gatewayBuildId
    || reported.gatewayApiVersion !== manifest.gatewayApiVersion
    || reported.sidecarVersion !== manifest.sidecarVersion
    || reported.sidecarBuildId !== manifest.sidecarBuildId
  ) {
    throw new SmokeCheckError("bundled runtime smoke check reported an identity mismatch", { reported });
  }
  return reported;
}
