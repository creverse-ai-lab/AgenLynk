// The one way a runtime tree is placed under runtimeRoot/versions/<id>/.
//
// First install (runtime-installer.js) and update (runtime-updater.js) both
// need exactly this: copy a seed into a scratch directory, verify the copy
// against its manifest, and only then atomically rename it into place. The two
// had verbatim copies of it, which had already drifted — one grew a
// post-rename confinement re-check the other lacked. Lives in its own module
// so both can import it without a cycle.

import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, cp, mkdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { promisify } from "node:util";
import { verifyRuntimeManifest } from "./runtime-manifest.js";

const execFileAsync = promisify(execFile);

// A distribution seed keeps the bulk of the runtime (the Gateway npm package,
// its `gateway` alias, and npm/npx) as one xz archive: about 60MB of small
// files on disk become a few MB in the app bundle. Node itself stays a plain
// file, since it is what runs this code. The manifest describes the unpacked
// tree, so a seed is only ever verified once laid out.
export const SEED_PAYLOAD_FILE = "runtime-payload.tar.xz";

export async function isPackedSeed(seedRoot) {
  try {
    await access(join(seedRoot, SEED_PAYLOAD_FILE));
    return true;
  } catch {
    return false;
  }
}

/**
 * Lays `seedRoot` out in `destination` as an installed runtime: the seed's
 * files, with a packed payload unpacked in place and the archive itself left
 * out. A seed without a payload is a plain copy.
 */
export async function materializeSeed(seedRoot, destination) {
  const archive = join(seedRoot, SEED_PAYLOAD_FILE);
  // Preserve relative link text exactly. Node's default (`false`) resolves
  // relative links against the source and rewrites them as absolute paths;
  // that both changes the manifest checksum and can make a copied link
  // escape the destination.
  await cp(seedRoot, destination, { recursive: true, verbatimSymlinks: true, filter: (source) => source !== archive });
  if (await isPackedSeed(seedRoot)) {
    // The system tar (libarchive) refuses absolute and ".." member paths by
    // default; the manifest check that follows rejects anything else extra.
    await execFileAsync("/usr/bin/tar", ["-xf", archive, "-C", destination], { maxBuffer: 1024 * 1024 });
  }
}

/**
 * Stages `seedRoot` into `target`, verifying before it replaces anything.
 *
 * `onFailure` wraps whatever went wrong into the caller's error vocabulary
 * (the installer throws plain Errors, the updater a coded RuntimeUpdaterError),
 * so the shared body stays free of either.
 */
export async function stageVerifiedRuntime({
  seedRoot,
  runtimeRoot,
  target,
  manifest,
  isConfined,
  onFailure,
  onConfinementViolation
}) {
  const stagingRoot = join(runtimeRoot, "staging");
  await mkdir(stagingRoot, { recursive: true });
  const staging = join(
    stagingRoot,
    `${manifest.gatewayVersion}-${manifest.gatewayBuildId}-${randomBytes(6).toString("hex")}`
  );
  await rm(staging, { recursive: true, force: true });
  try {
    await materializeSeed(seedRoot, staging);
    await verifyRuntimeManifest(staging, manifest);
    await mkdir(join(runtimeRoot, "versions"), { recursive: true });
    await rm(target, { recursive: true, force: true });
    await rename(staging, target);
  } catch (error) {
    await rm(staging, { recursive: true, force: true }).catch(() => {});
    throw onFailure(error);
  }
  // Lexical checks cannot see a symlink introduced on the path between
  // verification and rename, so confinement is re-checked by real path once
  // the candidate is finally in place.
  if (!(await isConfined(runtimeRoot, target))) {
    await rm(target, { recursive: true, force: true }).catch(() => {});
    throw onConfinementViolation();
  }
}
