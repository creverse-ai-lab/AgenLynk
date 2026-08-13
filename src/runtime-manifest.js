// Composite AgenLynk runtime manifest.
//
// A managed runtime contains three independent namespaces:
//   gateway/     exact, immutable Gateway release artifact from gateway.lock.json
//   node/        the one Node distribution shared by Gateway and the app sidecar
//   app-runtime/ AgenLynk-owned install/stage/activate/rollback tooling
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

export const RUNTIME_MANIFEST_FORMAT_VERSION = 4;
export const RUNTIME_MANIFEST_FILE_NAME = "runtime-manifest.json";
export const OFFICIAL_CODESIGN_TRANSFORMS_FILE = "official-codesign-transforms.json";
export const OFFICIAL_CODESIGN_TRANSFORM_PATHS = new Set([
  "node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64/claude"
]);
export const REQUIRED_RUNTIME_FILES = [
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

function assertGatewayLock(lock) {
  if (lock?.schemaVersion !== 1 || lock.version !== "1.4.0" || lock.tag !== "v1.4.0" || lock.apiMajor !== 1) {
    throw new Error("gateway.lock.json must pin Gateway v1.4.0 API major 1");
  }
  if (!/^[a-f0-9]{40}$/.test(lock.sourceCommit ?? "") || !/^[a-f0-9]{64}$/.test(lock.asset?.sha256 ?? "")) {
    throw new Error("gateway.lock.json release identity is invalid");
  }
  if (lock.runtimeRoot !== "acp-gateway-runtime" || lock.publicEntrypoint !== "gateway-client/index.js") {
    throw new Error("gateway.lock.json public runtime boundary is invalid");
  }
  if (lock.platform !== "darwin" || lock.arch !== "arm64") throw new Error("gateway.lock.json platform must be darwin-arm64");
}

async function readGatewayReleaseIdentity(root) {
  const lock = JSON.parse(await readFile(join(root, "gateway.lock.json"), "utf8"));
  assertGatewayLock(lock);
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

export async function verifyOfficialGatewayInventory(gatewayRoot, upstream, transforms = []) {
  if (!Array.isArray(upstream?.files) || !upstream.files.length) {
    throw new Error("Gateway artifact manifest file inventory is missing");
  }
  const transformByPath = indexOfficialCodesignTransforms(transforms, upstream);
  const expectedPaths = new Set(upstream.files.map((entry) => officialPathKey(entry.path)));
  expectedPaths.add("runtime-manifest.json");
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

export async function buildRuntimeManifest(root, { nodeVersion } = {}) {
  await assertRequiredFilesExist(root);
  const officialCodesignTransforms = await readOfficialCodesignTransforms(root);
  const identity = await readGatewayReleaseIdentity(root);
  await verifyOfficialGatewayInventory(join(root, "gateway"), identity.upstream, officialCodesignTransforms);
  const resolvedNodeVersion = nodeVersion ?? await readExecutableVersion(join(root, "node/bin/node"));
  const payload = await collectPayloadEntries(root);
  const runtimeBuildId = sha256Hex(JSON.stringify(payload)).slice(0, 16);
  return {
    formatVersion: RUNTIME_MANIFEST_FORMAT_VERSION,
    ...Object.fromEntries(Object.entries(identity).filter(([key]) => key !== "upstream")),
    runtimeBuildId,
    nodeVersion: resolvedNodeVersion,
    requiredFiles: REQUIRED_RUNTIME_FILES,
    officialCodesignTransforms,
    payload,
    generatedAt: new Date().toISOString()
  };
}

export async function verifyRuntimeManifest(root, manifest) {
  const startedAt = process.hrtime.bigint();
  if (!manifest || manifest.formatVersion !== RUNTIME_MANIFEST_FORMAT_VERSION) throw new Error("unsupported runtime manifest format");
  await assertRequiredFilesExist(root, manifest.requiredFiles ?? REQUIRED_RUNTIME_FILES);
  const identity = await readGatewayReleaseIdentity(root);
  for (const key of ["gatewayVersion", "gatewayBuildId", "gatewayApiVersion", "gatewayArtifactSha256", "gatewayManifestSha256"]) {
    if (identity[key] !== manifest[key]) throw new Error(`runtime ${key} does not match its lock/manifest`);
  }
  await verifyOfficialGatewayInventory(join(root, "gateway"), identity.upstream, manifest.officialCodesignTransforms ?? []);
  const nodeVersion = await readExecutableVersion(join(root, "node/bin/node"));
  if (manifest.nodeVersion !== nodeVersion) throw new Error(`installed Node version mismatch (expected ${manifest.nodeVersion}, found ${nodeVersion})`);
  await readExecutableVersion(join(root, "node/bin/npm"));
  await readExecutableVersion(join(root, "node/bin/npx"));
  const payload = await collectPayloadEntries(root);
  comparePayload(payload, manifest.payload ?? []);
  const runtimeBuildId = sha256Hex(JSON.stringify(payload)).slice(0, 16);
  if (runtimeBuildId !== manifest.runtimeBuildId) throw new Error("runtime build id does not match payload");
  return { ...Object.fromEntries(Object.entries(identity).filter(([key]) => key !== "upstream")), runtimeBuildId, verificationMs: Number(process.hrtime.bigint() - startedAt) / 1e6 };
}

export async function readManifestFile(root) {
  return JSON.parse(await readFile(join(root, RUNTIME_MANIFEST_FILE_NAME), "utf8"));
}
