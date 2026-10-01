#!/usr/bin/env node

// Build-time fetch of the Gateway runtime pinned by gateway.lock.json: the npm
// package acp-gateway-daemon, never a moving tag or a resolved dependency tree.
//
// 1. The registry tarball is downloaded (or read from --artifact) and must
//    match the lock's sha512 `integrity` before anything reads it.
// 2. Provenance: `npm audit signatures` verifies the registry signature and
//    the Sigstore-signed attestations of that exact version, and the verified
//    SLSA statement must name the lock's repository, workflow, tag, commit,
//    and integrity, with the signing certificate issued to that workflow.
// 3. The tarball (regular files under package/ only) is unpacked as-is into
//    <output>/node_modules/acp-gateway-daemon. The package bundles its whole
//    dependency tree, so no npm install runs and nothing is resolved.
// 4. <output>/gateway becomes a relative symlink to that directory, and
//    <output>/gateway-package.json records what was verified, including the
//    tarball's file inventory runtime-manifest.js later checks against.
//
// The package ships no Node. The app provides it (gateway.lock.json `node`,
// macos/scripts/prepare-node-runtime.sh).

import { execFile } from "node:child_process";
import { X509Certificate, createHash } from "node:crypto";
import { createReadStream, realpathSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rename, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import {
  GATEWAY_ALIAS_PATH,
  GATEWAY_CLIENT_ENTRYPOINT,
  GATEWAY_PACKAGE_PATH,
  GATEWAY_PACKAGE_RECORD_FILE,
  assertGatewayPackageLock,
  collectGatewayInventory
} from "../src/runtime-manifest.js";

const execFileAsync = promisify(execFile);
const repositoryRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const defaultLockPath = join(repositoryRoot, "gateway.lock.json");
const SLSA_PROVENANCE = "https://slsa.dev/provenance/v1";

export async function sha256File(path) {
  const hash = createHash("sha256");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return hash.digest("hex");
}

/** The npm `dist.integrity` form: `sha512-<base64 digest>`. */
export async function integrityOfFile(path) {
  const hash = createHash("sha512");
  for await (const chunk of createReadStream(path)) hash.update(chunk);
  return `sha512-${hash.digest("base64")}`;
}

export async function readGatewayLock(path = defaultLockPath) {
  return assertGatewayPackageLock(JSON.parse(await readFile(path, "utf8")));
}

function tarballFileName(lock) {
  return `${lock.package.name}-${lock.version}.tgz`;
}

async function download(url, destination, fetchImpl) {
  const response = await fetchImpl(url, { redirect: "follow" });
  if (!response.ok || !response.body) throw new Error(`Gateway package download failed: HTTP ${response.status}`);
  const bytes = new Uint8Array(await response.arrayBuffer());
  await writeFile(destination, bytes, { mode: 0o600 });
}

/** Download to a sibling tmp file, verify the sha512 integrity, then atomically replace the cache. A partial or mismatched download never becomes `cachedTarball`. */
export async function ensureCachedGatewayTarball({ lock, cacheRoot, fetchImpl }) {
  await mkdir(cacheRoot, { recursive: true });
  const cachedTarball = join(cacheRoot, tarballFileName(lock));
  try {
    if (await integrityOfFile(cachedTarball) === lock.package.integrity) return cachedTarball;
  } catch { /* missing or unreadable cache is a miss */ }
  const temporaryCache = join(cacheRoot, `.${tarballFileName(lock)}.${process.pid}.${Date.now()}.tmp`);
  try {
    await download(lock.package.tarball, temporaryCache, fetchImpl);
    const integrity = await integrityOfFile(temporaryCache);
    if (integrity !== lock.package.integrity) {
      throw new Error(`Gateway package integrity mismatch (expected ${lock.package.integrity}, found ${integrity})`);
    }
    await rename(temporaryCache, cachedTarball);
  } catch (error) {
    await rm(temporaryCache, { force: true }).catch(() => {});
    throw error;
  }
  return cachedTarball;
}

/**
 * Checks one `tar -tvzf` listing. npm tarballs hold regular files under
 * package/; a directory entry is tolerated, anything else (a link, a device,
 * a path escaping package/) rejects the whole tarball before it is unpacked.
 */
export function assertTarballListingSafe(verboseListing, names) {
  const types = verboseListing.split("\n").filter(Boolean).map((line) => line[0]);
  if (!names.length || types.length !== names.length) throw new Error("Gateway package tarball listing is unreadable");
  names.forEach((entry, index) => {
    if (types[index] !== "-" && types[index] !== "d") throw new Error(`Gateway package tarball has a non-file entry: ${entry}`);
    const normalized = entry.replace(/^\.\//, "").replace(/\/$/, "");
    if (!normalized || normalized.includes("\0") || isAbsolute(normalized)) throw new Error(`unsafe Gateway package entry: ${entry}`);
    const segments = normalized.split("/");
    if (segments.some((segment) => !segment || segment === "." || segment === "..")) throw new Error(`unsafe Gateway package entry: ${entry}`);
    if (segments[0] !== "package") throw new Error(`unexpected Gateway package root: ${entry}`);
  });
}

async function assertTarballSafe(tarball) {
  const [{ stdout: verbose }, { stdout: plain }] = await Promise.all([
    execFileAsync("tar", ["-tvzf", tarball], { maxBuffer: 64 * 1024 * 1024 }),
    execFileAsync("tar", ["-tzf", tarball], { maxBuffer: 64 * 1024 * 1024 })
  ]);
  assertTarballListingSafe(verbose, plain.split("\n").filter(Boolean));
}

function sriToHex(integrity) {
  return Buffer.from(integrity.slice("sha512-".length), "base64").toString("hex");
}

/**
 * Pure check of the one `npm audit signatures --json --include-attestations`
 * entry for the pinned package. npm has already verified the signatures; this
 * pins *whose* they are: the SLSA statement's subject, source, and build, and
 * the Fulcio certificate identity (the workflow that signed it).
 */
export function evaluateProvenance(entry, lock) {
  const fail = (reason) => { throw new Error(`Gateway package provenance: ${reason}`); };
  if (entry?.name !== lock.package.name || entry.version !== lock.version) fail("npm did not verify the pinned package");
  const bundle = (entry.attestationBundles ?? []).find((item) => item?.predicateType === SLSA_PROVENANCE)?.bundle;
  if (!bundle) fail("no verified SLSA provenance attestation");
  let statement;
  try {
    statement = JSON.parse(Buffer.from(bundle.dsseEnvelope?.payload ?? "", "base64").toString("utf8"));
  } catch {
    fail("the provenance statement is unreadable");
  }
  if (statement?.predicateType !== SLSA_PROVENANCE) fail("the statement is not SLSA provenance v1");
  const subject = statement.subject?.find((item) => item?.name === `pkg:npm/${lock.package.name}@${lock.version}`);
  if (!subject || subject.digest?.sha512 !== sriToHex(lock.package.integrity)) fail("the attested digest is not the pinned integrity");
  const workflow = statement.predicate?.buildDefinition?.externalParameters?.workflow;
  if (workflow?.repository !== lock.provenance.repository || workflow.path !== lock.provenance.workflow || workflow.ref !== lock.provenance.ref) {
    fail(`built by ${workflow?.repository}/${workflow?.path}@${workflow?.ref}, not the pinned workflow`);
  }
  const commits = (statement.predicate?.buildDefinition?.resolvedDependencies ?? []).map((item) => item?.digest?.gitCommit);
  if (!commits.includes(lock.sourceCommit)) fail(`the attested source commit is not ${lock.sourceCommit}`);
  const certificate = bundle.verificationMaterial?.certificate?.rawBytes
    ?? bundle.verificationMaterial?.x509CertificateChain?.certificates?.[0]?.rawBytes;
  if (!certificate) fail("the attestation carries no signing certificate");
  const identity = `URI:${lock.provenance.repository}/${lock.provenance.workflow}@${lock.provenance.ref}`;
  const certificateInfo = new X509Certificate(Buffer.from(certificate, "base64"));
  if (!(certificateInfo.subjectAltName ?? "").split(", ").includes(identity)) fail(`the signing certificate is not issued to ${identity}`);
  if (!/O=sigstore\.dev/.test(certificateInfo.issuer)) fail("the signing certificate is not issued by Sigstore");
  return {
    verified: true,
    predicateType: SLSA_PROVENANCE,
    repository: lock.provenance.repository,
    workflow: lock.provenance.workflow,
    ref: lock.provenance.ref,
    sourceCommit: lock.sourceCommit
  };
}

async function runNpmCommand(args, { cwd }) {
  const { stdout } = await execFileAsync(process.env.ACP_LYNK_NPM || "npm", args, {
    cwd,
    maxBuffer: 64 * 1024 * 1024,
    env: { ...process.env, npm_config_update_notifier: "false", npm_config_fund: "false" }
  });
  return stdout;
}

/**
 * Installs the pinned version from the registry into a scratch project (no
 * lifecycle scripts) purely so npm can verify its signatures and
 * attestations; the scratch tree is discarded. What the app ships is the
 * integrity-checked tarball, which must be the one npm verified.
 */
export async function verifyGatewayProvenance({ lock, runNpm = runNpmCommand }) {
  const scratch = await mkdtemp(join(tmpdir(), "agenlynk-gateway-provenance-"));
  try {
    await writeFile(join(scratch, "package.json"), `${JSON.stringify({
      name: "agenlynk-gateway-provenance",
      private: true,
      dependencies: { [lock.package.name]: lock.version }
    })}\n`);
    await runNpm(["install", "--ignore-scripts", "--no-audit", "--registry", lock.package.registry], { cwd: scratch });
    const installed = JSON.parse(await readFile(join(scratch, "package-lock.json"), "utf8"))
      ?.packages?.[`node_modules/${lock.package.name}`];
    if (installed?.version !== lock.version || installed.integrity !== lock.package.integrity || installed.resolved !== lock.package.tarball) {
      throw new Error("Gateway package provenance: npm resolved a different tarball than the lock pins");
    }
    let report;
    try {
      report = JSON.parse(await runNpm(["audit", "signatures", "--json", "--include-attestations", "--registry", lock.package.registry], { cwd: scratch }));
    } catch (error) {
      // A failed audit exits non-zero and still prints its JSON report.
      try { report = JSON.parse(error?.stdout ?? ""); } catch { throw error; }
    }
    const rejected = [...(report?.invalid ?? []), ...(report?.missing ?? [])].find((item) => item?.name === lock.package.name);
    if (rejected) throw new Error(`Gateway package provenance: npm could not verify ${lock.package.name}@${lock.version}`);
    // npm 10 (the one Node 22 bundles) accepts --include-attestations but
    // reports only failures, so there is no attestation to pin.
    if (!Array.isArray(report?.verified)) {
      throw new Error("Gateway package provenance: this npm does not report verified attestations; use npm 11 or newer (set ACP_LYNK_NPM)");
    }
    return evaluateProvenance((report?.verified ?? []).find((item) => item?.name === lock.package.name), lock);
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

async function readPackageJson(packageRoot, lock) {
  const packageJson = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  if (packageJson?.name !== lock.package.name || packageJson.version !== lock.version) {
    throw new Error(`Gateway package is ${packageJson?.name}@${packageJson?.version}, not ${lock.package.name}@${lock.version}`);
  }
  if (packageJson.exports?.["./client"] !== `./${GATEWAY_CLIENT_ENTRYPOINT}`) {
    throw new Error("Gateway package does not export its public client as ./client");
  }
  return packageJson;
}

/**
 * Writes node_modules/acp-gateway-daemon, the gateway alias, and
 * gateway-package.json into `outputRoot`, replacing only those three entries
 * (a seed root already holds app-runtime/ and more).
 */
export async function fetchGatewayRuntime({
  lockPath = defaultLockPath,
  artifactPath = process.env.ACP_LYNK_GATEWAY_ARTIFACT || "",
  outputRoot,
  cacheRoot = join(repositoryRoot, "build", "cache", "gateway"),
  fetchImpl = globalThis.fetch,
  verifyProvenance = verifyGatewayProvenance,
  skipProvenance = process.env.ACP_LYNK_GATEWAY_SKIP_PROVENANCE === "1"
}) {
  if (!outputRoot) throw new Error("outputRoot is required");
  const lock = await readGatewayLock(lockPath);
  const tarball = artifactPath
    ? resolve(artifactPath)
    : await ensureCachedGatewayTarball({ lock, cacheRoot, fetchImpl });
  const integrity = await integrityOfFile(tarball);
  if (integrity !== lock.package.integrity) {
    throw new Error(`Gateway package integrity mismatch (expected ${lock.package.integrity}, found ${integrity})`);
  }
  await assertTarballSafe(tarball);
  const provenance = skipProvenance
    ? { verified: false, reason: "skipped (ACP_LYNK_GATEWAY_SKIP_PROVENANCE=1); not for distribution" }
    : await verifyProvenance({ lock });

  await mkdir(outputRoot, { recursive: true });
  const temporary = await mkdtemp(join(resolve(outputRoot), ".gateway-fetch-"));
  try {
    await execFileAsync("tar", ["-xzf", tarball, "-C", temporary]);
    const unpacked = join(temporary, "package");
    await readPackageJson(unpacked, lock);
    const record = {
      schemaVersion: 1,
      name: lock.package.name,
      version: lock.version,
      tarball: lock.package.tarball,
      integrity: lock.package.integrity,
      sourceCommit: lock.sourceCommit,
      provenance,
      files: await collectGatewayInventory(unpacked)
    };
    await writeFile(join(temporary, GATEWAY_PACKAGE_RECORD_FILE), `${JSON.stringify(record, null, 2)}\n`);
    await symlink(GATEWAY_PACKAGE_PATH, join(temporary, GATEWAY_ALIAS_PATH));

    const packageTarget = join(outputRoot, GATEWAY_PACKAGE_PATH);
    await mkdir(dirname(packageTarget), { recursive: true });
    await rm(packageTarget, { recursive: true, force: true });
    await rename(unpacked, packageTarget);
    for (const name of [GATEWAY_ALIAS_PATH, GATEWAY_PACKAGE_RECORD_FILE]) {
      await rm(join(outputRoot, name), { recursive: true, force: true });
      await rename(join(temporary, name), join(outputRoot, name));
    }
    return { lock, tarball, outputRoot, provenance };
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

// realpath: invoked through a symlinked directory (/tmp on macOS), argv[1] and
// import.meta.url name the same file differently.
if (process.argv[1] && realpathSync(resolve(process.argv[1])) === fileURLToPath(import.meta.url)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (!options.outputRoot) throw new Error("--output <directory> is required");
    const result = await fetchGatewayRuntime(options);
    if (!result.provenance.verified) process.stderr.write(`fetch-gateway-runtime: warning: provenance ${result.provenance.reason}\n`);
    process.stdout.write(`${JSON.stringify({
      ok: true,
      package: `${result.lock.package.name}@${result.lock.version}`,
      provenanceVerified: result.provenance.verified,
      outputRoot: resolve(result.outputRoot)
    })}\n`);
  } catch (error) {
    process.stderr.write(`fetch-gateway-runtime: ${error?.message ?? String(error)}\n`);
    process.exitCode = 1;
  }
}
