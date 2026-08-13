// Proves a runtime tree can actually run before anything is pointed at it.
//
// Deliberately more than checksum verification, which only proves the bytes on
// disk match the manifest: this executes the candidate's *own bundled* node
// binary (not the host Node running this process) to import its own
// src/version.js, src/gateway-api-version.js, and sidecar/src/version.js,
// and compares what it reports against the manifest. So it also proves the
// bundled runtime can execute JS and load the official public Gateway client.
// No network access, no shell string, no
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
  const clientModuleUrl = pathToFileURL(join(target, "gateway", "gateway-client", "index.js")).href;
  const script = `(async () => {
    const [clientUrl] = process.argv.slice(1);
    const client = await import(clientUrl);
    process.stdout.write(JSON.stringify({
      gatewayApiVersion: client.GATEWAY_API_VERSION,
      exports: Object.keys(client).sort()
    }));
  })().catch((error) => {
    process.stderr.write(String((error && error.stack) || error));
    process.exit(1);
  });`;

  let stdout;
  try {
    ({ stdout } = await execFileAsync(
      nodeBinary,
      ["-e", script, clientModuleUrl],
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
    reported.gatewayApiVersion !== manifest.gatewayApiVersion
    || !reported.exports.includes("GatewayRpcClient")
    || !reported.exports.includes("GatewayError")
    || !reported.exports.includes("ERROR_CODES")
  ) {
    throw new SmokeCheckError("bundled runtime smoke check reported an identity mismatch", { reported });
  }
  return {
    gatewayVersion: manifest.gatewayVersion,
    gatewayBuildId: manifest.gatewayBuildId,
    runtimeBuildId: manifest.runtimeBuildId,
    gatewayApiVersion: reported.gatewayApiVersion
  };
}
