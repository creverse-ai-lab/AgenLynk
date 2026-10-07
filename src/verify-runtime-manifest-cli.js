#!/usr/bin/env node
// Build/package-time helper: verifies an already-assembled runtime directory
// against its own runtime-manifest.json — the same check runtime-installer.js
// performs before activating a copy, run here read-only against a runtime
// staged inside a built app (e.g. mounted from a DMG) without installing it.
// A packed seed (see runtime-staging.js) is unpacked first, into
// `--expand-to <dir>` when given (kept, so the caller can run what it holds),
// else into a temporary directory that is removed afterwards.
// Used by macos/scripts/build-app.sh and verify-dmg.sh.
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readManifestFile, verifyRuntimeManifest } from "./runtime-manifest.js";
import { isPackedSeed, materializeSeed } from "./runtime-staging.js";

const args = process.argv.slice(2);
const expandIndex = args.indexOf("--expand-to");
const expandTo = expandIndex >= 0 ? args[expandIndex + 1] : null;
const root = args.find((value, index) => !value.startsWith("--") && (expandIndex < 0 || index !== expandIndex + 1));
if (!root || (expandIndex >= 0 && !expandTo)) {
  process.stderr.write("usage: verify-runtime-manifest-cli.js <runtime root> [--expand-to <dir>]\n");
  process.exit(1);
}

let scratch = null;
try {
  const manifest = await readManifestFile(root);
  let verified = root;
  if (expandTo || await isPackedSeed(root)) {
    if (!expandTo) scratch = await mkdtemp(join(tmpdir(), "agenlynk-seed-"));
    verified = expandTo ?? join(scratch, "runtime");
    await materializeSeed(root, verified);
  }
  const result = await verifyRuntimeManifest(verified, manifest);
  process.stdout.write(
    `runtime manifest verified: ${manifest.gatewayVersion} (${manifest.gatewayBuildId}), gatewayApiVersion ${manifest.gatewayApiVersion}, `
    + `${manifest.payload.length} payload entries, ${result.verificationMs.toFixed(1)}ms`
    + `${verified === root ? "" : ` (unpacked to ${verified})`}\n`
  );
} catch (error) {
  process.stderr.write(`verify-runtime-manifest-cli: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
} finally {
  if (scratch) await rm(scratch, { recursive: true, force: true });
}
