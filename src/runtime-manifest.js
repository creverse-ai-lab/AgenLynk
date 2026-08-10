// Manifest for a Gateway runtime seed/installation: the same shape is used
// by the DMG build (to snapshot what it shipped) and by runtime-installer.js
// (to reject an incomplete/corrupt copy before it is activated). Reuses
// src/version.js's existing GATEWAY_VERSION/GATEWAY_BUILD_ID rather than
// inventing a separate identifier or hashing scheme: gatewayBuildId is
// re-derived by dynamically importing the *copied* version.js, so a
// corrupted or truncated src/**/*.js, package.json, or package-lock.json at
// that root produces a different id and fails verification. gatewayApiVersion
// is re-derived the same way from the copied gateway-api-version.js.
//
// On top of that identity check, the manifest also carries a complete,
// deterministic payload inventory (every regular file and symlink under the
// root, sorted by relative POSIX path, each with a sha256) so verification
// can catch a modified/missing/added file anywhere in the runtime — not just
// in the small REQUIRED_RUNTIME_FILES marker list.
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { access, readFile, readdir, readlink, stat } from "node:fs/promises";
import { delimiter, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { pathToFileURL } from "node:url";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

// Bumped alongside the payload/gatewayApiVersion fields added below: an
// older manifest shape (no payload inventory) must not be silently accepted
// as fully verified by the newer, stricter check.
export const RUNTIME_MANIFEST_FORMAT_VERSION = 2;

export const RUNTIME_MANIFEST_FILE_NAME = "runtime-manifest.json";

// Marker files whose presence (not full content) is checked directly,
// without spawning Node or importing anything. Kept short and cheap: this is
// an incomplete-copy guard, not a full integrity scan of node_modules.
export const REQUIRED_RUNTIME_FILES = [
  "package.json",
  "package-lock.json",
  "src/index.js",
  "src/guide.js",
  "src/bootstrap.js",
  "src/monitor.js",
  "src/version.js",
  "src/gateway-api-version.js",
  "src/installer.js",
  "skills/agent-delegator/SKILL.md",
  "node_modules/@agentclientprotocol/claude-agent-acp/package.json",
  "node_modules/@modelcontextprotocol/sdk/package.json",
  "node/bin/node",
  "node/bin/npm",
  "node/bin/npx"
];

export async function assertRequiredFilesExist(root, files = REQUIRED_RUNTIME_FILES) {
  for (const relativePath of files) {
    try {
      await access(join(root, relativePath));
    } catch {
      throw new Error(`runtime is missing a required file: ${relativePath}`);
    }
  }
}

/** Imports `<root>/src/version.js` so GATEWAY_BUILD_ID reflects that root's actual files. */
export async function readGatewayIdentity(root) {
  const versionModuleURL = pathToFileURL(join(root, "src", "version.js")).href;
  const module = await import(versionModuleURL);
  if (typeof module.GATEWAY_VERSION !== "string" || typeof module.GATEWAY_BUILD_ID !== "string") {
    throw new Error(`${root}/src/version.js did not export GATEWAY_VERSION/GATEWAY_BUILD_ID`);
  }
  return { gatewayVersion: module.GATEWAY_VERSION, gatewayBuildId: module.GATEWAY_BUILD_ID };
}

/** Imports `<root>/src/gateway-api-version.js` so a corrupted copy fails the same way as version.js. */
export async function readGatewayApiVersion(root) {
  const moduleURL = pathToFileURL(join(root, "src", "gateway-api-version.js")).href;
  const module = await import(moduleURL);
  if (!Number.isInteger(module.GATEWAY_API_VERSION)) {
    throw new Error(`${root}/src/gateway-api-version.js did not export an integer GATEWAY_API_VERSION`);
  }
  return module.GATEWAY_API_VERSION;
}

async function readExecutableVersion(binaryPath, args = ["--version"]) {
  // npm/npx use `#!/usr/bin/env node`. Finder-launched apps commonly inherit
  // a PATH without Node, so executing the bundled shim directly is not
  // sufficient: make its sibling bundled Node discoverable explicitly.
  const runtimeBin = dirname(binaryPath);
  const inheritedPath = process.env.PATH ?? "";
  const env = {
    ...process.env,
    PATH: inheritedPath ? `${runtimeBin}${delimiter}${inheritedPath}` : runtimeBin
  };
  const { stdout } = await execFileAsync(binaryPath, args, { env });
  return stdout.trim().replace(/^v/, "");
}

function sha256Hex(input) {
  return createHash("sha256").update(input).digest("hex");
}

// Above this size a file is streamed through sha256 (the bundled Node binary
// alone is hundreds of MB); below it, one readFile is markedly cheaper than
// stream machinery — the runtime's median payload file is ~2KB.
const STREAM_HASH_THRESHOLD_BYTES = 8 * 1024 * 1024;
// The payload hash is I/O-bound (only ~0.5s of the measured 1.5-2.4s wall is
// sha256 CPU), so overlapping reads cuts the wall time ~4x. Bounded so peak
// buffered memory stays ≤ pool × threshold.
const HASH_CONCURRENCY = 16;

async function hashFile(path) {
  const info = await stat(path);
  if (info.size <= STREAM_HASH_THRESHOLD_BYTES) {
    return sha256Hex(await readFile(path));
  }
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

/** Runs `tasks` (thunks) with at most `limit` in flight; rejects on first failure. */
async function runWithConcurrency(tasks, limit) {
  const executing = new Set();
  for (const task of tasks) {
    const promise = task().finally(() => executing.delete(promise));
    executing.add(promise);
    if (executing.size >= limit) await Promise.race(executing);
  }
  await Promise.all(executing);
}

/**
 * Rejects a symlink whose target — resolved lexically relative to the
 * symlink's own directory, never dereferenced on disk — would land outside
 * `root`. The raw target string (not its resolved contents) is what gets
 * recorded/hashed in the payload, so a symlink pointing outside the runtime
 * is never opened/read, only checked textually.
 */
function assertSymlinkConfined(root, relativePath, target) {
  if (isAbsolute(target)) {
    throw new Error(`runtime symlink target must be relative: ${relativePath} -> ${target}`);
  }
  const resolvedTarget = resolve(dirname(join(root, relativePath)), target);
  const relativeToRoot = relative(root, resolvedTarget);
  if (relativeToRoot === ".." || relativeToRoot.startsWith(`..${sep}`) || isAbsolute(relativeToRoot)) {
    throw new Error(`runtime symlink escapes its root: ${relativePath} -> ${target}`);
  }
}

/**
 * Walks the entire runtime root (regular files and symlinks; directories are
 * only traversed, never recorded on their own) into a stable, sorted payload
 * inventory. runtime-manifest.json itself is excluded so the manifest does
 * not need to describe itself. Symlinked directories are never followed —
 * `readdir(withFileTypes)` reports a symlink's own dirent type, so the walk
 * naturally treats it as a leaf instead of descending through it.
 */
async function collectPayloadEntries(root) {
  const entries = [];
  const fileHashTasks = [];

  async function walk(relativeDir) {
    const absoluteDir = relativeDir ? join(root, relativeDir) : root;
    const dirents = await readdir(absoluteDir, { withFileTypes: true });
    for (const dirent of dirents) {
      const relativePath = relativeDir ? `${relativeDir}/${dirent.name}` : dirent.name;
      if (!relativeDir && dirent.name === RUNTIME_MANIFEST_FILE_NAME) continue;
      const absolutePath = join(root, relativePath);
      if (dirent.isDirectory()) {
        await walk(relativePath);
      } else if (dirent.isSymbolicLink()) {
        const target = await readlink(absolutePath);
        assertSymlinkConfined(root, relativePath, target);
        entries.push({ path: relativePath, type: "symlink", target, sha256: sha256Hex(target) });
      } else if (dirent.isFile()) {
        // Record the entry in walk order, hash later with bounded overlap —
        // the hash pass is I/O-bound, and interleaving it into the walk made
        // it strictly sequential.
        const entry = { path: relativePath, type: "file", sha256: "" };
        entries.push(entry);
        fileHashTasks.push(async () => {
          entry.sha256 = await hashFile(absolutePath);
        });
      } else {
        throw new Error(`runtime contains an unsupported filesystem entry: ${relativePath}`);
      }
    }
  }

  await walk("");
  await runWithConcurrency(fileHashTasks, HASH_CONCURRENCY);
  entries.sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0));
  return entries;
}

function assertPayloadEntriesWellFormed(entries) {
  if (!Array.isArray(entries)) throw new Error("runtime manifest payload must be an array");
  const seen = new Set();
  for (const entry of entries) {
    const path = entry?.path;
    if (typeof path !== "string" || !path) throw new Error("runtime manifest payload entry is missing a path");
    const segments = path.split("/");
    if (isAbsolute(path) || segments.some((segment) => !segment || segment === "." || segment === "..")) {
      throw new Error(`runtime manifest payload contains an unsafe path: ${path}`);
    }
    if (seen.has(path)) throw new Error(`runtime manifest payload contains a duplicate path: ${path}`);
    seen.add(path);
    if (entry.type !== "file" && entry.type !== "symlink") {
      throw new Error(`runtime manifest payload entry has an unknown type: ${path}`);
    }
    if (typeof entry.sha256 !== "string" || !/^[a-f0-9]{64}$/.test(entry.sha256)) {
      throw new Error(`runtime manifest payload entry is missing a checksum: ${path}`);
    }
    if (entry.type === "symlink") {
      if (typeof entry.target !== "string" || sha256Hex(entry.target) !== entry.sha256) {
        throw new Error(`runtime manifest symlink entry is inconsistent: ${path}`);
      }
    }
  }
}

/** Compares two already-validated, path-sorted payload lists; throws describing every mismatch found. */
function comparePayload(actualEntries, expectedEntries) {
  assertPayloadEntriesWellFormed(expectedEntries);
  const actualByPath = new Map(actualEntries.map((entry) => [entry.path, entry]));
  const expectedByPath = new Map(expectedEntries.map((entry) => [entry.path, entry]));

  const missing = [];
  const modified = [];
  for (const [path, expected] of expectedByPath) {
    const actual = actualByPath.get(path);
    if (!actual) {
      missing.push(path);
    } else if (
      actual.type !== expected.type
      || actual.sha256 !== expected.sha256
      || (actual.type === "symlink" && actual.target !== expected.target)
    ) {
      modified.push(path);
    }
  }
  const unexpected = [...actualByPath.keys()].filter((path) => !expectedByPath.has(path));

  if (missing.length || modified.length || unexpected.length) {
    const summarize = (label, paths) => (paths.length ? [`${label} (${paths.length}): ${paths.slice(0, 5).join(", ")}${paths.length > 5 ? ", ..." : ""}`] : []);
    const details = [...summarize("missing", missing), ...summarize("modified", modified), ...summarize("unexpected", unexpected)];
    throw new Error(`runtime payload does not match its manifest — ${details.join("; ")}`);
  }
}

export async function buildRuntimeManifest(root, { nodeVersion } = {}) {
  await assertRequiredFilesExist(root);
  const identity = await readGatewayIdentity(root);
  const gatewayApiVersion = await readGatewayApiVersion(root);
  const resolvedNodeVersion = nodeVersion ?? await readExecutableVersion(join(root, "node/bin/node"));
  const payload = await collectPayloadEntries(root);
  return {
    formatVersion: RUNTIME_MANIFEST_FORMAT_VERSION,
    gatewayVersion: identity.gatewayVersion,
    gatewayBuildId: identity.gatewayBuildId,
    gatewayApiVersion,
    nodeVersion: resolvedNodeVersion,
    requiredFiles: REQUIRED_RUNTIME_FILES,
    payload,
    generatedAt: new Date().toISOString()
  };
}

/**
 * Re-derives a root's identity/executables/payload and throws with an
 * actionable message on the first mismatch. Used both right after staging a
 * copy (reject before activating) and as a fast idempotency check on every
 * startup (skip re-copying an already-valid installed version). Each file is
 * hashed exactly once (the payload walk below); nothing here re-hashes a
 * file already covered by an earlier step in the same call. The returned
 * `verificationMs` lets a caller report the real cost of checking an actual
 * bundle instead of guessing.
 */
export async function verifyRuntimeManifest(root, manifest) {
  const startedAt = process.hrtime.bigint();
  if (!manifest || manifest.formatVersion !== RUNTIME_MANIFEST_FORMAT_VERSION) {
    throw new Error("unsupported runtime manifest format");
  }
  await assertRequiredFilesExist(root, manifest.requiredFiles ?? REQUIRED_RUNTIME_FILES);

  const identity = await readGatewayIdentity(root);
  if (identity.gatewayVersion !== manifest.gatewayVersion || identity.gatewayBuildId !== manifest.gatewayBuildId) {
    throw new Error(
      `runtime content does not match its manifest (expected ${manifest.gatewayVersion}/${manifest.gatewayBuildId}, found ${identity.gatewayVersion}/${identity.gatewayBuildId})`
    );
  }

  const gatewayApiVersion = await readGatewayApiVersion(root);
  if (gatewayApiVersion !== manifest.gatewayApiVersion) {
    throw new Error(`Gateway API version mismatch (expected ${manifest.gatewayApiVersion}, found ${gatewayApiVersion})`);
  }

  const nodeVersion = await readExecutableVersion(join(root, "node/bin/node"));
  if (manifest.nodeVersion && nodeVersion !== manifest.nodeVersion) {
    throw new Error(`installed Node version mismatch (expected ${manifest.nodeVersion}, found ${nodeVersion})`);
  }
  // npm/npx must actually execute (not just exist) so a corrupted symlink/shim
  // is rejected the same way a corrupted node binary would be.
  await readExecutableVersion(join(root, "node/bin/npm"));
  await readExecutableVersion(join(root, "node/bin/npx"));

  const payloadEntries = await collectPayloadEntries(root);
  comparePayload(payloadEntries, manifest.payload ?? []);

  const verificationMs = Number(process.hrtime.bigint() - startedAt) / 1e6;
  return { ...identity, gatewayApiVersion, verificationMs };
}

export async function readManifestFile(root) {
  return JSON.parse(await readFile(join(root, RUNTIME_MANIFEST_FILE_NAME), "utf8"));
}
