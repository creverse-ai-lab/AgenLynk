#!/usr/bin/env node
// Build-time helper: snapshots Gateway, sidecar, and Node identities plus
// the required-file list of a fully assembled runtime directory (Node dist,
// node_modules, skills, src/ all copied in) into runtime-manifest.json.
// runtime-installer.js reads this later to reject an incomplete/corrupt
// staged copy before activating it. Run by build-app.sh after every other
// runtime asset has been copied into place; the executing Node here can be
// any modern build-machine Node — it only inspects the target root's own
// files and its own bundled node/bin/node, never itself becomes part of it.
import { writeFile } from "node:fs/promises";
import { join } from "node:path";
import { buildRuntimeManifest, verifyRuntimeManifest } from "./runtime-manifest.js";

const root = process.argv[2];
if (!root) {
  process.stderr.write("usage: build-runtime-manifest-cli.js <runtime root>\n");
  process.exit(1);
}

try {
  const manifest = await buildRuntimeManifest(root);
  await writeFile(join(root, "runtime-manifest.json"), `${JSON.stringify(manifest, null, 2)}\n`);
  // Self-verify immediately: proves the manifest this build just wrote
  // actually re-verifies against the same root (catching a bug in the
  // walk/hash logic here, not just at first install) and reports the real
  // cost of checking this bundle rather than a guess.
  const { verificationMs } = await verifyRuntimeManifest(root, manifest);
  process.stdout.write(
    `runtime-manifest.json: Gateway ${manifest.gatewayVersion} (${manifest.gatewayBuildId}), sidecar ${manifest.sidecarVersion} (${manifest.sidecarBuildId}), gatewayApiVersion ${manifest.gatewayApiVersion}, `
    + `node ${manifest.nodeVersion}, ${manifest.payload.length} payload entries, verified in ${verificationMs.toFixed(1)}ms\n`
  );
} catch (error) {
  process.stderr.write(`build-runtime-manifest-cli: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}
