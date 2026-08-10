#!/usr/bin/env node
// Build/package-time helper: verifies an already-assembled runtime directory
// against its own runtime-manifest.json — the same check runtime-installer.js
// performs before activating a copy, run here read-only against a runtime
// staged inside a built app (e.g. mounted from a DMG) without installing it.
// Used by macos/scripts/verify-dmg.sh.
import { readManifestFile, verifyRuntimeManifest } from "./runtime-manifest.js";

const root = process.argv[2];
if (!root) {
  process.stderr.write("usage: verify-runtime-manifest-cli.js <runtime root>\n");
  process.exit(1);
}

try {
  const manifest = await readManifestFile(root);
  const result = await verifyRuntimeManifest(root, manifest);
  process.stdout.write(
    `runtime manifest verified: ${manifest.gatewayVersion} (${manifest.gatewayBuildId}), gatewayApiVersion ${manifest.gatewayApiVersion}, `
    + `${manifest.payload.length} payload entries, ${result.verificationMs.toFixed(1)}ms\n`
  );
} catch (error) {
  process.stderr.write(`verify-runtime-manifest-cli: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}
