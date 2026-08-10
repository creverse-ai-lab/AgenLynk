#!/usr/bin/env node
// Build-time helper: assembles build/Lynk.release.json purely from what was
// actually built/signed/packaged (staged Info.plist values, the real DMG's
// bytes/sha256, the runtime seed's own runtime-manifest.json) — never
// hard-coded guesses. Run by macos/scripts/build-dmg.sh after hdiutil
// packaging, optional notarization/stapling, and verify-dmg.sh have all
// completed successfully.
import { writeFile } from "node:fs/promises";
import { readManifestFile } from "./runtime-manifest.js";

export const RELEASE_MANIFEST_FORMAT_VERSION = 1;

function parseArgs(argv) {
  const args = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) continue;
    const eq = token.indexOf("=");
    if (eq !== -1) {
      args[token.slice(2, eq)] = token.slice(eq + 1);
    } else {
      args[token.slice(2)] = argv[++index];
    }
  }
  return args;
}

function requireArg(args, name) {
  const value = args[name];
  if (typeof value !== "string" || !value) throw new Error(`--${name} is required`);
  return value;
}

function requireBooleanArg(args, name) {
  const value = requireArg(args, name);
  if (value !== "true" && value !== "false") {
    throw new Error(`--${name} must be true or false, got: ${value}`);
  }
  return value === "true";
}

try {
  const args = parseArgs(process.argv.slice(2));
  const runtimeManifest = await readManifestFile(requireArg(args, "runtime-root"));

  const signingMode = requireArg(args, "signing-mode");
  if (signingMode !== "ad-hoc" && signingMode !== "developer-id") {
    throw new Error(`--signing-mode must be ad-hoc or developer-id, got: ${signingMode}`);
  }
  const signingIdentity = args["signing-identity"] || null;
  if (signingMode === "developer-id" && !signingIdentity) {
    throw new Error("--signing-identity is required for developer-id signing");
  }
  if (!Number.isInteger(runtimeManifest.gatewayApiVersion)) {
    throw new Error("runtime manifest is missing an integer gatewayApiVersion");
  }

  const release = {
    schemaVersion: RELEASE_MANIFEST_FORMAT_VERSION,
    generatedAt: new Date().toISOString(),
    app: {
      name: requireArg(args, "app-name"),
      version: requireArg(args, "app-version"),
      buildNumber: requireArg(args, "app-build"),
      bundleId: requireArg(args, "bundle-id"),
      minimumMacOS: requireArg(args, "min-macos"),
      architecture: requireArg(args, "arch")
    },
    dmg: {
      name: requireArg(args, "dmg-name"),
      bytes: Number(requireArg(args, "dmg-bytes")),
      sha256: requireArg(args, "dmg-sha256")
    },
    gateway: {
      version: runtimeManifest.gatewayVersion,
      buildId: runtimeManifest.gatewayBuildId,
      apiVersion: runtimeManifest.gatewayApiVersion
    },
    node: {
      version: runtimeManifest.nodeVersion
    },
    // Never inferred/guessed: the mode+identity reflect what codesign
    // actually reported on the built app (see build-dmg.sh), and
    // notarized/stapled are only ever true when that step actually ran and
    // succeeded — both false is the accurate default for a local build.
    signing: {
      mode: signingMode,
      identity: signingIdentity,
      notarized: requireBooleanArg(args, "notarized"),
      stapled: requireBooleanArg(args, "stapled")
    }
  };

  if (!Number.isFinite(release.dmg.bytes) || release.dmg.bytes <= 0) {
    throw new Error(`--dmg-bytes must be a positive number, got: ${args["dmg-bytes"]}`);
  }
  if (!/^[a-f0-9]{64}$/.test(release.dmg.sha256)) {
    throw new Error("--dmg-sha256 must be a lowercase 64-character SHA-256 digest");
  }

  const out = requireArg(args, "out");
  await writeFile(out, `${JSON.stringify(release, null, 2)}\n`);
  process.stdout.write(
    `${out}: ${release.app.name} ${release.app.version} (${release.app.buildNumber}), `
    + `dmg ${release.dmg.name} ${release.dmg.bytes} bytes, signing=${release.signing.mode}, `
    + `notarized=${release.signing.notarized}, stapled=${release.signing.stapled}\n`
  );
} catch (error) {
  process.stderr.write(`build-release-manifest-cli: ${error?.message ?? String(error)}\n`);
  process.exitCode = 1;
}
