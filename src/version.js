import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, extname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const GATEWAY_VERSION = "1.3.1";

// The release version intentionally stays stable while dev work is in flight.
// A daemon can therefore report the right version while still running older
// code. Hash the shipped runtime sources once at process start so installers
// can distinguish that stale process from the current checkout.
export const GATEWAY_BUILD_ID = gatewayBuildId();

function gatewayBuildId() {
  const sourceRoot = dirname(fileURLToPath(import.meta.url));
  const hash = createHash("sha256");
  const files = readdirSync(sourceRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && [".js", ".html"].includes(extname(entry.name)))
    .map((entry) => entry.name)
    .sort();
  for (const name of files) {
    const data = readFileSync(join(sourceRoot, name));
    hash.update(`src/${name}`);
    hash.update("\0");
    hash.update(data);
    hash.update("\0");
  }
  const packageRoot = dirname(sourceRoot);
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
