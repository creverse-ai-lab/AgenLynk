import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const GATEWAY_VERSION = "1.3.2";

// The release version intentionally stays stable while dev work is in flight.
// A daemon can therefore report the right version while still running older
// code. Hash the shipped runtime sources once at process start so installers
// can distinguish that stale process from the current checkout.
export const GATEWAY_BUILD_ID = gatewayBuildId();

// The filesystem root this process is actually executing from — either an
// installed `~/.acp-gateway/runtime/versions/<version>-<buildId>/` directory
// (see src/runtime-installer.js) or a developer source checkout. Derived from
// this module's own location rather than a second identifier scheme, so it
// always reflects the code that is really running.
export const GATEWAY_RUNTIME_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

// "installed" when this process runs from a version-pinned install directory
// (its parent directory is literally named "versions"); "source-checkout"
// for a dev checkout, CI run, or anything else running in place.
export const GATEWAY_RUNTIME_SOURCE =
  basename(dirname(GATEWAY_RUNTIME_ROOT)) === "versions" ? "installed" : "source-checkout";

// Hashes every shipped file under `root`, depth-first in sorted order so the
// digest is stable across machines and filesystems. Entries are keyed by their
// path relative to the runtime root, so moving a file changes the build id.
function hashPayloadTree(hash, root, prefix) {
  if (!existsSync(root)) return;
  const entries = readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isFile() || entry.isDirectory())
    .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
  for (const entry of entries) {
    const path = join(root, entry.name);
    const relativePath = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) {
      hashPayloadTree(hash, path, relativePath);
      continue;
    }
    hash.update(relativePath);
    hash.update("\0");
    hash.update(readFileSync(path));
    hash.update("\0");
  }
}

/**
 * The build id for a runtime rooted at `packageRoot`. Exported so tests can
 * assert that a nested payload file is actually covered — an id that ignored
 * one would let an installed runtime look current while missing files.
 */
export function computeGatewayBuildId(packageRoot) {
  const sourceRoot = join(packageRoot, "src");
  const hash = createHash("sha256");
  // The whole of src/ and skills/, not just top-level scripts: the runtime
  // payload also carries nested Gateway assets (e.g. src/providers/), and a build
  // id that ignored them would leave an already-installed runtime looking
  // current while missing files the app just shipped. The sidecar namespace
  // is fingerprinted independently by sidecar/src/version.js.
  hashPayloadTree(hash, sourceRoot, "src");
  hashPayloadTree(hash, join(packageRoot, "skills"), "skills");
  // node_modules is pinned by the lockfile rather than hashed directly.
  for (const name of ["package.json", "package-lock.json"]) {
    const path = join(packageRoot, name);
    if (!existsSync(path)) continue;
    hash.update(name);
    hash.update("\0");
    hash.update(readFileSync(path));
    hash.update("\0");
  }
  return hash.digest("hex").slice(0, 16);
}

function gatewayBuildId() {
  return computeGatewayBuildId(dirname(dirname(fileURLToPath(import.meta.url))));
}
