// Composite AgenLynk runtime manifest.
//
// A managed runtime (format 5, Gateway 1.7+) contains these namespaces:
//   node_modules/acp-gateway-daemon/  the exact npm package pinned by
//                gateway.lock.json (sha512 integrity + npm provenance), as
//                unpacked from its tarball; nothing is added or resolved
//   gateway ->   relative symlink to node_modules/acp-gateway-daemon, kept so
//                agent MCP configs written against runtime/current/gateway/
//                keep resolving across the switch from the runtime tarball
//   gateway-package.json  what fetch-gateway-runtime.js verified: package
//                identity, provenance, and the tarball's file inventory
//   node/        the one Node distribution shared by Gateway and the app
//                sidecar; the npm package ships none, so the app provides the
//                version gateway.lock.json pins
//   app-runtime/ AgenLynk-owned install/stage/activate/rollback tooling
//
// Format 4 (Gateway <= 1.6) mounted the GitHub runtime tarball at gateway/
// instead. It is still verified, never built from the current lock, so an
// installed 1.6 runtime stays usable as the upgrade source and as a rollback
// target.
//
// The sidecar is intentionally not part of this tree. It is versioned with the
// app and runs from Contents/Resources/sidecar.
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { access, lstat, readFile, readdir, readlink, stat } from "node:fs/promises";
import { delimiter, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export const RUNTIME_MANIFEST_FORMAT_VERSION = 5;
export const LEGACY_TARBALL_MANIFEST_FORMAT_VERSION = 4;
export const RUNTIME_MANIFEST_FILE_NAME = "runtime-manifest.json";
export const GATEWAY_PACKAGE_NAME = "acp-gateway-daemon";
export const GATEWAY_PACKAGE_PATH = `node_modules/${GATEWAY_PACKAGE_NAME}`;
export const GATEWAY_ALIAS_PATH = "gateway";
export const GATEWAY_PACKAGE_RECORD_FILE = "gateway-package.json";
export const GATEWAY_CLIENT_ENTRYPOINT = "gateway-client/index.js";
export const OFFICIAL_CODESIGN_TRANSFORMS_FILE = "official-codesign-transforms.json";
export const OFFICIAL_CODESIGN_TRANSFORM_PATHS = new Set([
  "node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
]);
export const REQUIRED_RUNTIME_FILES = [
  "gateway.lock.json",
  GATEWAY_PACKAGE_RECORD_FILE,
  `${GATEWAY_PACKAGE_PATH}/package.json`,
  `${GATEWAY_PACKAGE_PATH}/src/index.js`,
  `${GATEWAY_PACKAGE_PATH}/src/guide.js`,
  `${GATEWAY_PACKAGE_PATH}/src/bootstrap.js`,
  `${GATEWAY_PACKAGE_PATH}/src/gateway-daemon.js`,
  `${GATEWAY_PACKAGE_PATH}/${GATEWAY_CLIENT_ENTRYPOINT}`,
  // Through the alias: the paths existing MCP configs launch.
  `${GATEWAY_ALIAS_PATH}/src/index.js`,
  `${GATEWAY_ALIAS_PATH}/src/guide.js`,
  "app-runtime/runtime-installer-cli.js",
  "app-runtime/runtime-installer.js",
  "app-runtime/runtime-updater-cli.js",
  "app-runtime/runtime-updater.js",
  "node/bin/node",
  "node/bin/npm",
  "node/bin/npx"
];
export const LEGACY_TARBALL_REQUIRED_RUNTIME_FILES = [
  "gateway.lock.json",
  "gateway/runtime-manifest.json",
  "gateway/package.json",
  "gateway/package-lock.json",
  "gateway/src/index.js",
  "gateway/src/bootstrap.js",
  "gateway/gateway-client/index.js",
  "app-runtime/runtime-installer-cli.js",
  "app-runtime/runtime-installer.js",
  "app-runtime/runtime-updater-cli.js",
  "app-runtime/runtime-updater.js",
  "node/bin/node",
  "node/bin/npm",
  "node/bin/npx"
];

function sha256Hex(input) {
  return createHash("sha256").update(input).digest("hex");
}

async function hashFile(path) {
  const info = await stat(path);
  if (info.size <= 8 * 1024 * 1024) return sha256Hex(await readFile(path));
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export function runtimeVersionId(manifest) {
  if (typeof manifest?.gatewayVersion !== "string" || !manifest.gatewayVersion
    || typeof manifest?.runtimeBuildId !== "string" || !/^[a-f0-9]{16}$/.test(manifest.runtimeBuildId)) {
    throw new Error("runtime version id requires gatewayVersion and runtimeBuildId");
  }
  return `${manifest.gatewayVersion}-${manifest.runtimeBuildId}`;
}

// Kept as a compatibility shim while updater result objects are migrated.
// It deliberately returns no sidecar fields: the sidecar no longer belongs to
// a Gateway runtime version.
export function runtimeSidecarIdentity() {
  return {};
}

export function runtimePointerIdentityMismatch(pointer, manifest) {
  return !pointer || !manifest
    || pointer.gatewayVersion !== manifest.gatewayVersion
    || pointer.gatewayBuildId !== manifest.gatewayBuildId
    || pointer.runtimeBuildId !== manifest.runtimeBuildId;
}

export async function assertRequiredFilesExist(root, files = REQUIRED_RUNTIME_FILES) {
  for (const relativePath of files) {
    try { await access(join(root, relativePath)); }
    catch { throw new Error(`runtime is missing a required file: ${relativePath}`); }
  }
}

const RELEASE_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const SHA512_INTEGRITY = /^sha512-[A-Za-z0-9+/]{86}==$/;

/**
 * gateway.lock.json schema 2: the npm package, its provenance, and the Node
 * the app provides for it. Shared with scripts/fetch-gateway-runtime.js so the
 * build and every later verification read one definition.
 */
export function assertGatewayPackageLock(lock) {
  if (lock?.schemaVersion !== 2
    || typeof lock.version !== "string"
    || !RELEASE_VERSION.test(lock.version)
    || lock.tag !== `v${lock.version}`
    || lock.apiMajor !== 1) {
    throw new Error("gateway.lock.json must identify a versioned Gateway API major 1 release");
  }
  if (!/^[a-f0-9]{40}$/.test(lock.sourceCommit ?? "")) throw new Error("gateway.lock.json sourceCommit is invalid");
  const pkg = lock.package;
  if (pkg?.name !== GATEWAY_PACKAGE_NAME
    || pkg.installPath !== GATEWAY_PACKAGE_PATH
    || pkg.clientSpecifier !== `${GATEWAY_PACKAGE_NAME}/client`
    || !/^https:\/\/.+\/$/.test(pkg.registry ?? "")
    || pkg.tarball !== `${pkg.registry}${pkg.name}/-/${pkg.name}-${lock.version}.tgz`) {
    throw new Error("gateway.lock.json npm package identity is invalid");
  }
  if (!SHA512_INTEGRITY.test(pkg.integrity ?? "")) throw new Error("gateway.lock.json package integrity must be a sha512 SRI");
  const provenance = lock.provenance;
  if (provenance?.predicateType !== "https://slsa.dev/provenance/v1"
    || !/^https:\/\/github\.com\/[^/]+\/[^/]+$/.test(provenance.repository ?? "")
    || !/^\.github\/workflows\/[^/]+\.ya?ml$/.test(provenance.workflow ?? "")
    || provenance.ref !== `refs/tags/${lock.tag}`) {
    throw new Error("gateway.lock.json provenance identity is invalid");
  }
  const node = lock.node;
  if (node?.provider !== "app"
    || !/^\d+\.\d+\.\d+$/.test(node.version ?? "")
    || node.installPath !== "node"
    || node.distribution !== `https://nodejs.org/download/release/v${node.version}/node-v${node.version}-darwin-arm64.tar.xz`
    || !/^[a-f0-9]{64}$/.test(node.sha256 ?? "")) {
    throw new Error("gateway.lock.json must pin the app-provided Node distribution");
  }
  if (lock.publicEntrypoint !== GATEWAY_CLIENT_ENTRYPOINT) throw new Error("gateway.lock.json public runtime boundary is invalid");
  if (lock.platform !== "darwin" || lock.arch !== "arm64") throw new Error("gateway.lock.json platform must be darwin-arm64");
  return lock;
}

/**
 * The digest Gateway itself reports as setup.gatewayBuildId (see its
 * src/runtime-identity.js): sha256 over each src/*.js name, a NUL, and its
 * bytes, in sorted order. Recording the same value lets the monitor compare
 * the running daemon with the active runtime (annotateRuntimeSplit); the npm
 * package carries no runtime-manifest.json, so the daemon has no source
 * commit to report instead.
 *
 * This follows Gateway's method on purpose: when Gateway changes how it
 * computes the id, this function changes with it. package-smoke compares the
 * two against a live daemon (runtimeIdentity "verified"), so a release build
 * fails instead of shipping a runtime that always reads as split.
 */
export async function gatewaySourceDigest(packageRoot) {
  const hash = createHash("sha256");
  const names = (await readdir(join(packageRoot, "src"))).filter((name) => name.endsWith(".js")).sort();
  for (const name of names) hash.update(name).update("\0").update(await readFile(join(packageRoot, "src", name)));
  return hash.digest("hex");
}

async function readGatewayPackageIdentity(root) {
  const lock = assertGatewayPackageLock(JSON.parse(await readFile(join(root, "gateway.lock.json"), "utf8")));
  const recordPath = join(root, GATEWAY_PACKAGE_RECORD_FILE);
  const record = JSON.parse(await readFile(recordPath, "utf8"));
  const recordMatches = record?.schemaVersion === 1
    && record.name === lock.package.name
    && record.version === lock.version
    && record.integrity === lock.package.integrity
    && record.tarball === lock.package.tarball
    && record.sourceCommit === lock.sourceCommit;
  if (!recordMatches) throw new Error("Gateway package record does not match gateway.lock.json");
  if (!Array.isArray(record.files) || !record.files.length) throw new Error("Gateway package file inventory is missing");
  const packageRoot = join(root, GATEWAY_PACKAGE_PATH);
  const packageJson = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  if (packageJson?.name !== lock.package.name || packageJson.version !== lock.version) {
    throw new Error("installed Gateway package.json does not match gateway.lock.json");
  }
  if (packageJson.exports?.["./client"] !== `./${GATEWAY_CLIENT_ENTRYPOINT}`) {
    throw new Error("installed Gateway package does not export its public client as ./client");
  }
  let alias;
  try { alias = await readlink(join(root, GATEWAY_ALIAS_PATH)); }
  catch { throw new Error(`runtime ${GATEWAY_ALIAS_PATH} must be a symlink to ${GATEWAY_PACKAGE_PATH}`); }
  if (alias !== GATEWAY_PACKAGE_PATH) throw new Error(`runtime ${GATEWAY_ALIAS_PATH} must be a symlink to ${GATEWAY_PACKAGE_PATH}`);
  return {
    identity: {
      gatewayVersion: lock.version,
      gatewayBuildId: await gatewaySourceDigest(packageRoot),
      gatewaySourceCommit: lock.sourceCommit,
      gatewayApiVersion: lock.apiMajor,
      gatewayPackage: lock.package.name,
      gatewayIntegrity: lock.package.integrity,
      gatewayRecordSha256: await hashFile(recordPath)
    },
    lock,
    record,
    packageRoot
  };
}

const PACKAGE_IDENTITY_KEYS = [
  "gatewayVersion",
  "gatewayBuildId",
  "gatewaySourceCommit",
  "gatewayApiVersion",
  "gatewayPackage",
  "gatewayIntegrity",
  "gatewayRecordSha256"
];

// ---- format 4: the GitHub runtime tarball mounted at gateway/ ----

function assertLegacyGatewayLock(lock) {
  if (lock?.schemaVersion !== 1
    || typeof lock.version !== "string"
    || !RELEASE_VERSION.test(lock.version)
    || lock.tag !== `v${lock.version}`
    || lock.apiMajor !== 1) {
    throw new Error("gateway.lock.json must identify a versioned Gateway API major 1 release");
  }
  if (!/^[a-f0-9]{40}$/.test(lock.sourceCommit ?? "") || !/^[a-f0-9]{64}$/.test(lock.asset?.sha256 ?? "")) {
    throw new Error("gateway.lock.json release identity is invalid");
  }
  if (lock.runtimeRoot !== "acp-gateway-runtime" || lock.publicEntrypoint !== GATEWAY_CLIENT_ENTRYPOINT) {
    throw new Error("gateway.lock.json public runtime boundary is invalid");
  }
  if (lock.platform !== "darwin" || lock.arch !== "arm64") throw new Error("gateway.lock.json platform must be darwin-arm64");
}

async function readLegacyGatewayReleaseIdentity(root) {
  const lock = JSON.parse(await readFile(join(root, "gateway.lock.json"), "utf8"));
  assertLegacyGatewayLock(lock);
  const upstream = JSON.parse(await readFile(join(root, "gateway", "runtime-manifest.json"), "utf8"));
  const matches = upstream?.schemaVersion === 1
    && upstream.package === "acp-gateway"
    && upstream.version === lock.version
    && upstream.apiMajor === lock.apiMajor
    && upstream.platform === lock.platform
    && upstream.arch === lock.arch
    && upstream.runtimeRoot === lock.runtimeRoot
    && upstream.publicEntrypoint === `./${lock.publicEntrypoint}`
    && upstream.artifact === lock.asset.name
    && upstream.source?.tag === lock.tag
    && upstream.source?.commit === lock.sourceCommit;
  if (!matches) throw new Error("Gateway artifact manifest does not match gateway.lock.json");
  if (!Array.isArray(upstream.files) || !upstream.files.length) throw new Error("Gateway artifact manifest file inventory is missing");
  return {
    gatewayVersion: lock.version,
    gatewayBuildId: lock.sourceCommit,
    gatewayApiVersion: lock.apiMajor,
    gatewayArtifactSha256: lock.asset.sha256,
    gatewayManifestSha256: await hashFile(join(root, "gateway", "runtime-manifest.json")),
    upstream
  };
}

const LEGACY_IDENTITY_KEYS = ["gatewayVersion", "gatewayBuildId", "gatewayApiVersion", "gatewayArtifactSha256", "gatewayManifestSha256"];

async function readLockSchemaVersion(root) {
  return JSON.parse(await readFile(join(root, "gateway.lock.json"), "utf8"))?.schemaVersion;
}

function confinedToGatewayRoot(root, candidate) {
  const relativePath = relative(root, candidate);
  return relativePath !== "" && relativePath !== ".." && !relativePath.startsWith(`..${sep}`) && !isAbsolute(relativePath);
}

function officialPathKey(path) {
  return typeof path === "string" ? path.replace(/\/$/, "") : "";
}

export async function readOfficialCodesignTransforms(root) {
  try {
    const raw = JSON.parse(await readFile(join(root, OFFICIAL_CODESIGN_TRANSFORMS_FILE), "utf8"));
    if (!Array.isArray(raw)) throw new Error("official-codesign-transforms.json must be an array");
    return raw;
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

function indexOfficialCodesignTransforms(transforms, upstream) {
  if (transforms == null) return new Map();
  if (!Array.isArray(transforms)) throw new Error("official codesign transforms must be an array");
  const officialFiles = new Map(
    upstream.files
      .filter((entry) => entry?.type === "file")
      .map((entry) => [officialPathKey(entry.path), entry])
  );
  const byPath = new Map();
  for (const transform of transforms) {
    if (transform?.kind !== "codesign") throw new Error("only codesign official transforms are allowed");
    const path = officialPathKey(transform.path);
    if (!OFFICIAL_CODESIGN_TRANSFORM_PATHS.has(path)) {
      throw new Error(`official codesign transform path is not allowed: ${path}`);
    }
    const official = officialFiles.get(path);
    if (!official) throw new Error(`official codesign transform does not name an official file: ${path}`);
    if (transform.officialSha256 !== official.sha256) {
      throw new Error(`official codesign transform officialSha256 does not match files[]: ${path}`);
    }
    if (!/^[a-f0-9]{64}$/.test(transform.installedSha256 ?? "")) {
      throw new Error(`official codesign transform installedSha256 is invalid: ${path}`);
    }
    if (transform.installedSha256 === transform.officialSha256) {
      throw new Error(`official codesign transform does not change bytes: ${path}`);
    }
    if (byPath.has(path)) throw new Error(`duplicate official codesign transform: ${path}`);
    byPath.set(path, transform);
  }
  return byPath;
}

async function verifyOfficialManifestEntry(root, record, transform) {
  const relativePath = officialPathKey(record?.path);
  const absolute = join(root, ...relativePath.split("/"));
  if (!relativePath || !confinedToGatewayRoot(root, absolute)) {
    throw new Error(`official Gateway manifest path escapes runtime root: ${record?.path}`);
  }
  const info = await lstat(absolute);
  if (record.type === "directory") {
    if (!info.isDirectory()) throw new Error(`official Gateway manifest type mismatch: ${record.path}`);
    return;
  }
  if (record.type === "file") {
    if (!info.isFile()) throw new Error(`official Gateway manifest type mismatch: ${record.path}`);
    const digest = await hashFile(absolute);
    if (digest === record.sha256) {
      if (transform) throw new Error(`official codesign transform does not match installed bytes: ${record.path}`);
      return;
    }
    if (!transform) throw new Error(`official Gateway file checksum mismatch: ${record.path}`);
    if (digest !== transform.installedSha256) {
      throw new Error(`official codesign transform does not match installed bytes: ${record.path}`);
    }
    return;
  }
  if (record.type === "symlink") {
    const target = await readlink(absolute);
    const resolved = resolve(dirname(absolute), target);
    if (target !== record.target || !confinedToGatewayRoot(root, resolved)) {
      throw new Error(`official Gateway manifest symlink mismatch: ${record.path}`);
    }
    return;
  }
  throw new Error(`official Gateway manifest entry type is invalid: ${record.path}`);
}

/**
 * Proves `gatewayRoot` holds exactly the official inventory: every listed
 * entry with its recorded bytes, and nothing else. `extraPaths` names files
 * that sit beside the inventory without being part of it (the runtime
 * tarball's own runtime-manifest.json).
 */
export async function verifyOfficialGatewayInventory(gatewayRoot, upstream, transforms = [], { extraPaths = [] } = {}) {
  if (!Array.isArray(upstream?.files) || !upstream.files.length) {
    throw new Error("Gateway artifact manifest file inventory is missing");
  }
  const transformByPath = indexOfficialCodesignTransforms(transforms, upstream);
  const expectedPaths = new Set(upstream.files.map((entry) => officialPathKey(entry.path)));
  for (const path of extraPaths) expectedPaths.add(path);
  const actualPaths = new Set();
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const absolute = join(directory, entry.name);
      const rel = relative(gatewayRoot, absolute).split(sep).join("/");
      actualPaths.add(rel);
      if (entry.isDirectory()) await walk(absolute);
    }
  }
  await walk(gatewayRoot);
  for (const path of actualPaths) {
    if (!expectedPaths.has(path)) throw new Error(`official Gateway payload has an unexpected entry: ${path}`);
  }
  for (const path of expectedPaths) {
    if (!actualPaths.has(path)) throw new Error(`official Gateway payload is missing an entry: ${path}`);
  }
  for (const record of upstream.files) {
    await verifyOfficialManifestEntry(gatewayRoot, record, transformByPath.get(officialPathKey(record.path)));
  }
}

/**
 * The inventory format verifyOfficialGatewayInventory checks, taken from a
 * freshly unpacked npm tarball (fetch-gateway-runtime.js). npm packages carry
 * regular files only, so anything else means the tree is not a plain unpack.
 */
export async function collectGatewayInventory(packageRoot) {
  const files = [];
  async function walk(relativeDirectory) {
    const directory = relativeDirectory ? join(packageRoot, relativeDirectory) : packageRoot;
    for (const child of await readdir(directory, { withFileTypes: true })) {
      const path = relativeDirectory ? `${relativeDirectory}/${child.name}` : child.name;
      if (child.isDirectory()) {
        files.push({ path: `${path}/`, type: "directory" });
        await walk(path);
      } else if (child.isFile()) {
        const absolute = join(packageRoot, path);
        files.push({ path, type: "file", bytes: (await stat(absolute)).size, sha256: await hashFile(absolute) });
      } else {
        throw new Error(`Gateway package contains an unsupported filesystem entry: ${path}`);
      }
    }
  }
  await walk("");
  files.sort((left, right) => (left.path < right.path ? -1 : left.path > right.path ? 1 : 0));
  return files;
}

async function readExecutableVersion(binaryPath, args = ["--version"]) {
  const runtimeBin = dirname(binaryPath);
  const inheritedPath = process.env.PATH ?? "";
  const env = { ...process.env, PATH: inheritedPath ? `${runtimeBin}${delimiter}${inheritedPath}` : runtimeBin };
  const { stdout } = await execFileAsync(binaryPath, args, { env });
  return stdout.trim().replace(/^v/, "");
}

function assertSymlinkConfined(root, relativePath, target) {
  if (isAbsolute(target)) throw new Error(`runtime symlink target must be relative: ${relativePath}`);
  const resolvedTarget = resolve(dirname(join(root, relativePath)), target);
  const relativeToRoot = relative(root, resolvedTarget);
  if (relativeToRoot === ".." || relativeToRoot.startsWith(`..${sep}`) || isAbsolute(relativeToRoot)) {
    throw new Error(`runtime symlink escapes its root: ${relativePath}`);
  }
}

async function collectPayloadEntries(root) {
  const entries = [];
  async function walk(relativeDirectory) {
    const directory = relativeDirectory ? join(root, relativeDirectory) : root;
    const children = await readdir(directory, { withFileTypes: true });
    children.sort((left, right) => left.name.localeCompare(right.name));
    for (const child of children) {
      const path = relativeDirectory ? `${relativeDirectory}/${child.name}` : child.name;
      if (!relativeDirectory && child.name === RUNTIME_MANIFEST_FILE_NAME) continue;
      const absolute = join(root, path);
      if (child.isDirectory()) await walk(path);
      else if (child.isSymbolicLink()) {
        const target = await readlink(absolute);
        assertSymlinkConfined(root, path, target);
        entries.push({ path, type: "symlink", target, sha256: sha256Hex(target) });
      } else if (child.isFile()) entries.push({ path, type: "file", sha256: await hashFile(absolute) });
      else throw new Error(`runtime contains an unsupported filesystem entry: ${path}`);
    }
  }
  await walk("");
  entries.sort((left, right) => left.path.localeCompare(right.path));
  return entries;
}

function assertPayloadEntriesWellFormed(entries) {
  if (!Array.isArray(entries)) throw new Error("runtime manifest payload must be an array");
  const seen = new Set();
  for (const entry of entries) {
    const segments = typeof entry?.path === "string" ? entry.path.split("/") : [];
    if (!segments.length || segments.some((segment) => !segment || segment === "." || segment === "..") || isAbsolute(entry.path)) {
      throw new Error(`runtime manifest payload contains an unsafe path: ${entry?.path}`);
    }
    if (seen.has(entry.path)) throw new Error(`runtime manifest payload contains a duplicate path: ${entry.path}`);
    seen.add(entry.path);
    if (!new Set(["file", "symlink"]).has(entry.type) || !/^[a-f0-9]{64}$/.test(entry.sha256 ?? "")) {
      throw new Error(`runtime manifest payload entry is invalid: ${entry.path}`);
    }
    if (entry.type === "symlink" && (typeof entry.target !== "string" || sha256Hex(entry.target) !== entry.sha256)) {
      throw new Error(`runtime manifest symlink entry is inconsistent: ${entry.path}`);
    }
  }
}

function comparePayload(actual, expected) {
  assertPayloadEntriesWellFormed(expected);
  if (JSON.stringify(actual) === JSON.stringify(expected)) return;
  const actualByPath = new Map(actual.map((entry) => [entry.path, entry]));
  const expectedByPath = new Map(expected.map((entry) => [entry.path, entry]));
  const missing = [...expectedByPath.keys()].filter((path) => !actualByPath.has(path));
  const unexpected = [...actualByPath.keys()].filter((path) => !expectedByPath.has(path));
  const modified = [...expectedByPath].filter(([path, entry]) => {
    const found = actualByPath.get(path);
    return found && JSON.stringify(found) !== JSON.stringify(entry);
  }).map(([path]) => path);
  throw new Error(`runtime payload does not match its manifest — missing: ${missing.slice(0, 5).join(", ")}; modified: ${modified.slice(0, 5).join(", ")}; unexpected: ${unexpected.slice(0, 5).join(", ")}`);
}

async function verifyNodeDistribution(root, expectedVersion) {
  const nodeVersion = await readExecutableVersion(join(root, "node/bin/node"));
  if (expectedVersion !== nodeVersion) throw new Error(`installed Node version mismatch (expected ${expectedVersion}, found ${nodeVersion})`);
  await readExecutableVersion(join(root, "node/bin/npm"));
  await readExecutableVersion(join(root, "node/bin/npx"));
}

/**
 * Builds a format 5 manifest from a root assembled against the current lock
 * (schema 2). The bundled Node must be the version the lock pins, and the
 * package record must carry a verified provenance: a seed fetched with the
 * provenance check skipped is for local development and is never sealed.
 */
export async function buildRuntimeManifest(root, { nodeVersion } = {}) {
  if (await readLockSchemaVersion(root) === 1) return buildLegacyTarballRuntimeManifest(root, { nodeVersion });
  await assertRequiredFilesExist(root);
  const { identity, lock, record, packageRoot } = await readGatewayPackageIdentity(root);
  if (record.provenance?.verified !== true) {
    throw new Error("Gateway package provenance was not verified; refetch without skipping the provenance check");
  }
  await verifyOfficialGatewayInventory(packageRoot, record);
  const resolvedNodeVersion = nodeVersion ?? await readExecutableVersion(join(root, "node/bin/node"));
  if (resolvedNodeVersion !== lock.node.version) {
    throw new Error(`bundled Node ${resolvedNodeVersion} is not the Node ${lock.node.version} gateway.lock.json pins`);
  }
  const payload = await collectPayloadEntries(root);
  const runtimeBuildId = sha256Hex(JSON.stringify(payload)).slice(0, 16);
  return {
    formatVersion: RUNTIME_MANIFEST_FORMAT_VERSION,
    ...identity,
    runtimeBuildId,
    nodeVersion: resolvedNodeVersion,
    requiredFiles: REQUIRED_RUNTIME_FILES,
    payload,
    generatedAt: new Date().toISOString()
  };
}

/** Format 4, for a root carrying a schema 1 lock and the mounted runtime tarball. */
async function buildLegacyTarballRuntimeManifest(root, { nodeVersion } = {}) {
  await assertRequiredFilesExist(root, LEGACY_TARBALL_REQUIRED_RUNTIME_FILES);
  const officialCodesignTransforms = await readOfficialCodesignTransforms(root);
  const identity = await readLegacyGatewayReleaseIdentity(root);
  await verifyOfficialGatewayInventory(join(root, "gateway"), identity.upstream, officialCodesignTransforms, { extraPaths: ["runtime-manifest.json"] });
  const resolvedNodeVersion = nodeVersion ?? await readExecutableVersion(join(root, "node/bin/node"));
  const payload = await collectPayloadEntries(root);
  const runtimeBuildId = sha256Hex(JSON.stringify(payload)).slice(0, 16);
  return {
    formatVersion: LEGACY_TARBALL_MANIFEST_FORMAT_VERSION,
    ...Object.fromEntries(Object.entries(identity).filter(([key]) => key !== "upstream")),
    runtimeBuildId,
    nodeVersion: resolvedNodeVersion,
    requiredFiles: LEGACY_TARBALL_REQUIRED_RUNTIME_FILES,
    officialCodesignTransforms,
    payload,
    generatedAt: new Date().toISOString()
  };
}

export async function verifyRuntimeManifest(root, manifest) {
  const startedAt = process.hrtime.bigint();
  let identity;
  if (manifest?.formatVersion === RUNTIME_MANIFEST_FORMAT_VERSION) {
    await assertRequiredFilesExist(root, REQUIRED_RUNTIME_FILES);
    const inspected = await readGatewayPackageIdentity(root);
    identity = inspected.identity;
    if (inspected.record.provenance?.verified !== true) throw new Error("runtime Gateway package provenance was not verified");
    // Inventory first: a changed package file then reads as exactly that,
    // rather than as the gatewayBuildId it also changes.
    await verifyOfficialGatewayInventory(inspected.packageRoot, inspected.record);
    for (const key of PACKAGE_IDENTITY_KEYS) {
      if (identity[key] !== manifest[key]) throw new Error(`runtime ${key} does not match its lock/manifest`);
    }
    if (manifest.nodeVersion !== inspected.lock.node.version) {
      throw new Error(`runtime Node ${manifest.nodeVersion} is not the Node ${inspected.lock.node.version} its lock pins`);
    }
  } else if (manifest?.formatVersion === LEGACY_TARBALL_MANIFEST_FORMAT_VERSION) {
    await assertRequiredFilesExist(root, manifest.requiredFiles ?? LEGACY_TARBALL_REQUIRED_RUNTIME_FILES);
    const { upstream, ...legacy } = await readLegacyGatewayReleaseIdentity(root);
    identity = legacy;
    for (const key of LEGACY_IDENTITY_KEYS) {
      if (identity[key] !== manifest[key]) throw new Error(`runtime ${key} does not match its lock/manifest`);
    }
    await verifyOfficialGatewayInventory(join(root, "gateway"), upstream, manifest.officialCodesignTransforms ?? [], { extraPaths: ["runtime-manifest.json"] });
  } else {
    throw new Error("unsupported runtime manifest format");
  }
  await verifyNodeDistribution(root, manifest.nodeVersion);
  const payload = await collectPayloadEntries(root);
  comparePayload(payload, manifest.payload ?? []);
  const runtimeBuildId = sha256Hex(JSON.stringify(payload)).slice(0, 16);
  if (runtimeBuildId !== manifest.runtimeBuildId) throw new Error("runtime build id does not match payload");
  return { ...identity, runtimeBuildId, verificationMs: Number(process.hrtime.bigint() - startedAt) / 1e6 };
}

export async function readManifestFile(root) {
  return JSON.parse(await readFile(join(root, RUNTIME_MANIFEST_FILE_NAME), "utf8"));
}
