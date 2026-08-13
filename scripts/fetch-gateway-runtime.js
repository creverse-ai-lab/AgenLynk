#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { createReadStream } from "node:fs";
import { access, cp, lstat, mkdir, mkdtemp, readFile, readdir, readlink, rename, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const defaultLockPath = join(repositoryRoot, "gateway.lock.json");

export async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

export async function readGatewayLock(path = defaultLockPath) {
  const lock = JSON.parse(await readFile(path, "utf8"));
  if (lock?.schemaVersion !== 1) throw new Error("gateway lock schemaVersion must be 1");
  if (lock.version !== "1.4.0" || lock.tag !== "v1.4.0" || lock.apiMajor !== 1) {
    throw new Error("gateway lock must pin Gateway v1.4.0 API major 1");
  }
  if (!/^[a-f0-9]{40}$/.test(lock.sourceCommit ?? "")) throw new Error("gateway lock sourceCommit is invalid");
  if (!lock.asset?.name || !/^https:\/\//.test(lock.asset?.url ?? "")) throw new Error("gateway lock asset is incomplete");
  if (!/^[a-f0-9]{64}$/.test(lock.asset?.sha256 ?? "")) throw new Error("gateway lock asset SHA-256 is invalid");
  if (lock.runtimeRoot !== "acp-gateway-runtime" || lock.publicEntrypoint !== "gateway-client/index.js") {
    throw new Error("gateway lock runtime boundary is invalid");
  }
  if (lock.platform !== "darwin" || lock.arch !== "arm64") throw new Error("gateway lock platform must be darwin-arm64");
  return lock;
}

async function download(url, destination, fetchImpl) {
  const response = await fetchImpl(url, { redirect: "follow" });
  if (!response.ok || !response.body) throw new Error(`Gateway artifact download failed: HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  const { writeFile } = await import("node:fs/promises");
  await writeFile(destination, bytes, { mode: 0o600 });
}

/** Download to a sibling tmp file, verify SHA-256, then atomically replace the cache. A partial or mismatched download never becomes `cachedArchive`. */
export async function ensureCachedGatewayArchive({ lock, cacheRoot, fetchImpl }) {
  await mkdir(cacheRoot, { recursive: true });
  const cachedArchive = join(cacheRoot, lock.asset.name);
  try {
    if (await sha256File(cachedArchive) === lock.asset.sha256) return cachedArchive;
  } catch { /* missing or unreadable cache is a miss */ }
  const temporaryCache = join(cacheRoot, `.${lock.asset.name}.${process.pid}.${Date.now()}.tmp`);
  try {
    await download(lock.asset.url, temporaryCache, fetchImpl);
    const digest = await sha256File(temporaryCache);
    if (digest !== lock.asset.sha256) {
      throw new Error(`Gateway artifact SHA-256 mismatch (expected ${lock.asset.sha256}, found ${digest})`);
    }
    await rename(temporaryCache, cachedArchive);
  } catch (error) {
    await rm(temporaryCache, { force: true }).catch(() => {});
    throw error;
  }
  return cachedArchive;
}

function assertArchiveEntrySafe(entry, expectedRoot) {
  const normalized = entry.replace(/^\.\//, "").replace(/\/$/, "");
  if (!normalized || normalized.includes("\0") || isAbsolute(normalized)) throw new Error(`unsafe Gateway archive entry: ${entry}`);
  const segments = normalized.split("/");
  if (segments.some((segment) => !segment || segment === "." || segment === "..")) {
    throw new Error(`unsafe Gateway archive entry: ${entry}`);
  }
  if (segments[0] !== expectedRoot) throw new Error(`unexpected Gateway archive root: ${entry}`);
}

async function assertArchiveSafe(archivePath, lock) {
  const { stdout } = await execFileAsync("tar", ["-tzf", archivePath], { maxBuffer: 32 * 1024 * 1024 });
  const entries = stdout.split("\n").filter(Boolean);
  if (!entries.length) throw new Error("Gateway archive is empty");
  for (const entry of entries) assertArchiveEntrySafe(entry, lock.runtimeRoot);
}

function confined(root, candidate) {
  const rel = relative(root, candidate);
  return rel !== "" && rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel);
}

async function verifyManifestFile(root, record) {
  const path = join(root, ...record.path.replace(/\/$/, "").split("/"));
  if (!confined(root, path)) throw new Error(`Gateway manifest path escapes runtime root: ${record.path}`);
  const info = await lstat(path);
  if (record.type === "directory") {
    if (!info.isDirectory()) throw new Error(`Gateway manifest type mismatch: ${record.path}`);
    return;
  }
  if (record.type === "file") {
    if (!info.isFile() || await sha256File(path) !== record.sha256) throw new Error(`Gateway manifest checksum mismatch: ${record.path}`);
    return;
  }
  if (record.type === "symlink") {
    const target = await readlink(path);
    const resolved = resolve(dirname(path), target);
    if (target !== record.target || !confined(root, resolved)) throw new Error(`Gateway manifest symlink mismatch: ${record.path}`);
    return;
  }
  throw new Error(`Gateway manifest entry type is invalid: ${record.path}`);
}

export async function verifyExtractedGateway(root, lock) {
  const manifest = JSON.parse(await readFile(join(root, "runtime-manifest.json"), "utf8"));
  const expected = {
    schemaVersion: 1,
    package: "acp-gateway",
    version: lock.version,
    apiMajor: lock.apiMajor,
    platform: lock.platform,
    arch: lock.arch,
    runtimeRoot: lock.runtimeRoot,
    publicEntrypoint: `./${lock.publicEntrypoint}`,
    artifact: lock.asset.name
  };
  for (const [key, value] of Object.entries(expected)) {
    if (manifest[key] !== value) throw new Error(`Gateway manifest ${key} mismatch`);
  }
  if (manifest.source?.tag !== lock.tag || manifest.source?.commit !== lock.sourceCommit) {
    throw new Error("Gateway manifest source identity does not match lock");
  }
  if (!Array.isArray(manifest.files) || !manifest.files.length) throw new Error("Gateway manifest files are missing");
  const expectedPaths = new Set(manifest.files.map((entry) => entry.path.replace(/\/$/, "")));
  expectedPaths.add("runtime-manifest.json");
  const actualPaths = new Set();
  async function walk(directory) {
    for (const entry of await readdir(directory, { withFileTypes: true })) {
      const path = join(directory, entry.name);
      const rel = relative(root, path).split(sep).join("/");
      actualPaths.add(rel);
      if (entry.isDirectory()) await walk(path);
    }
  }
  await walk(root);
  for (const path of actualPaths) if (!expectedPaths.has(path)) throw new Error(`Gateway payload has an unexpected entry: ${path}`);
  for (const path of expectedPaths) if (!actualPaths.has(path)) throw new Error(`Gateway payload is missing an entry: ${path}`);
  for (const record of manifest.files) await verifyManifestFile(root, record);
  await access(join(root, lock.publicEntrypoint));
  return manifest;
}

export async function fetchGatewayRuntime({
  lockPath = defaultLockPath,
  artifactPath = process.env.ACP_LYNK_GATEWAY_ARTIFACT || "",
  outputRoot,
  cacheRoot = join(repositoryRoot, "build", "cache", "gateway"),
  fetchImpl = globalThis.fetch
}) {
  if (!outputRoot) throw new Error("outputRoot is required");
  const lock = await readGatewayLock(lockPath);
  const archive = artifactPath
    ? resolve(artifactPath)
    : await ensureCachedGatewayArchive({ lock, cacheRoot, fetchImpl });
  const digest = await sha256File(archive);
  if (digest !== lock.asset.sha256) throw new Error(`Gateway artifact SHA-256 mismatch (expected ${lock.asset.sha256}, found ${digest})`);
  await assertArchiveSafe(archive, lock);
  const temporary = await mkdtemp(join(tmpdir(), "agenlynk-gateway-"));
  try {
    await execFileAsync("tar", ["-xzf", archive, "-C", temporary]);
    const extracted = join(temporary, lock.runtimeRoot);
    await verifyExtractedGateway(extracted, lock);
    const staged = `${outputRoot}.tmp-${process.pid}`;
    await rm(staged, { recursive: true, force: true });
    await cp(extracted, staged, { recursive: true, verbatimSymlinks: true });
    await rm(outputRoot, { recursive: true, force: true });
    await rename(staged, outputRoot);
    return { lock, archive, outputRoot };
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

function parseArgs(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === "--output") result.outputRoot = argv[++index];
    else if (value === "--artifact") result.artifactPath = argv[++index];
    else if (value === "--lock") result.lockPath = argv[++index];
    else if (value === "--cache") result.cacheRoot = argv[++index];
    else throw new Error(`unknown argument: ${value}`);
  }
  return result;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (!options.outputRoot) throw new Error("--output <directory> is required");
    const result = await fetchGatewayRuntime(options);
    process.stdout.write(`${JSON.stringify({ ok: true, version: result.lock.version, outputRoot: resolve(result.outputRoot) })}\n`);
  } catch (error) {
    process.stderr.write(`fetch-gateway-runtime: ${error?.message ?? String(error)}\n`);
    process.exitCode = 1;
  }
}
