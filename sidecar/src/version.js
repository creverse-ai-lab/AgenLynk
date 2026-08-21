import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const SIDECAR_VERSION = "0.4.1";
export const SIDECAR_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
export const SIDECAR_RUNTIME_ROOT = dirname(SIDECAR_ROOT);
export const SIDECAR_BUILD_ID = computeSidecarBuildId(SIDECAR_ROOT);

export function computeSidecarBuildId(sidecarRoot) {
  const hash = createHash("sha256");
  hashTree(hash, join(sidecarRoot, "src"), "src");
  const packagePath = join(sidecarRoot, "package.json");
  if (existsSync(packagePath)) {
    hash.update("package.json\0");
    hash.update(readFileSync(packagePath));
    hash.update("\0");
  }
  return hash.digest("hex").slice(0, 16);
}

function hashTree(hash, root, prefix) {
  if (!existsSync(root)) return;
  const entries = readdirSync(root, { withFileTypes: true })
    .filter((entry) => entry.isFile() || entry.isDirectory())
    .sort((left, right) => left.name.localeCompare(right.name));
  for (const entry of entries) {
    const path = join(root, entry.name);
    const relativePath = `${prefix}/${entry.name}`;
    if (entry.isDirectory()) {
      hashTree(hash, path, relativePath);
      continue;
    }
    hash.update(`${relativePath}\0`);
    hash.update(readFileSync(path));
    hash.update("\0");
  }
}
