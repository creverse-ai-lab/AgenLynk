// Proves a runtime tree can actually run before anything is pointed at it.
//
// Deliberately more than checksum verification, which only proves the bytes on
// disk match the manifest: this executes the candidate's *own bundled* node
// binary (not the host Node running this process) and has it load the official
// public Gateway client the way a consumer does. For the npm package (format
// 5) that is the bare specifier `acp-gateway-daemon/client` resolved from the
// runtime root, so the package's `exports` boundary is what gets exercised; a
// mounted runtime tarball (format 4) has no node_modules entry and is loaded
// from gateway/gateway-client/index.js as before. So it also proves the
// bundled runtime can execute JS. No network access, no shell string, no
// randomness: same target -> same result every time.
//
// Both the manual updater and the app's automatic upgrade gate on this — an
// automatic replacement that skipped it could leave a machine pointed at a
// runtime that cannot start.

import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { promisify } from "node:util";
import {
  GATEWAY_ALIAS_PATH,
  GATEWAY_CLIENT_ENTRYPOINT,
  GATEWAY_PACKAGE_NAME,
  GATEWAY_PACKAGE_PATH,
  RUNTIME_MANIFEST_FORMAT_VERSION
} from "./runtime-manifest.js";

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
  const npmLayout = manifest?.formatVersion === RUNTIME_MANIFEST_FORMAT_VERSION;
  const clientSpecifier = npmLayout
    ? `${GATEWAY_PACKAGE_NAME}/client`
    : pathToFileURL(join(target, "gateway", GATEWAY_CLIENT_ENTRYPOINT)).href;
  const script = `(async () => {
    const [specifier] = process.argv.slice(1);
    const client = await import(specifier);
    process.stdout.write(JSON.stringify({
      gatewayApiVersion: client.GATEWAY_API_VERSION,
      exports: Object.keys(client).sort(),
      resolved: import.meta.resolve(specifier)
    }));
  })().catch((error) => {
    process.stderr.write(String((error && error.stack) || error));
    process.exit(1);
  });`;

  let stdout;
  try {
    ({ stdout } = await execFileAsync(
      nodeBinary,
      ["--input-type=module", "--eval", script, clientSpecifier],
      // A bare specifier in --eval resolves from the working directory.
      { cwd: target, timeout: 10_000 }
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
  if (npmLayout) {
    // The specifier must land on the pinned package's own entrypoint, and the
    // gateway alias existing MCP configs launch through must reach the same file.
    const [resolved, expected, throughAlias] = await Promise.all([
      realpath(fileURLToPath(reported.resolved ?? "file:///")).catch(() => null),
      realpath(join(target, GATEWAY_PACKAGE_PATH, GATEWAY_CLIENT_ENTRYPOINT)).catch(() => null),
      realpath(join(target, GATEWAY_ALIAS_PATH, GATEWAY_CLIENT_ENTRYPOINT)).catch(() => null)
    ]);
    if (!expected || resolved !== expected || throughAlias !== expected) {
      throw new SmokeCheckError("bundled runtime smoke check resolved the public client outside the pinned package", { reported });
    }
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
