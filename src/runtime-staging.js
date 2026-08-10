// The one way a runtime tree is placed under runtimeRoot/versions/<id>/.
//
// First install (runtime-installer.js) and update (runtime-updater.js) both
// need exactly this: copy a seed into a scratch directory, verify the copy
// against its manifest, and only then atomically rename it into place. The two
// had verbatim copies of it, which had already drifted — one grew a
// post-rename confinement re-check the other lacked. Lives in its own module
// so both can import it without a cycle.

import { randomBytes } from "node:crypto";
import { cp, mkdir, rename, rm } from "node:fs/promises";
import { join } from "node:path";
import { verifyRuntimeManifest } from "./runtime-manifest.js";

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
    // Preserve relative link text exactly. Node's default (`false`) resolves
    // relative links against the source and rewrites them as absolute paths;
    // that both changes the manifest checksum and can make a copied link
    // escape the staging root.
    await cp(seedRoot, staging, { recursive: true, verbatimSymlinks: true });
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
