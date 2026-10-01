import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { access, lstat, mkdir, mkdtemp, readdir, readFile, readlink, rm, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { promisify } from "node:util";
import {
  assertTarballListingSafe,
  ensureCachedGatewayTarball,
  evaluateProvenance,
  fetchGatewayRuntime,
  integrityOfFile,
  readGatewayLock,
  verifyGatewayProvenance
} from "../scripts/fetch-gateway-runtime.js";

const execFileAsync = promisify(execFile);
const auditEntry = JSON.parse(await readFile(new URL("./fixtures/npm-audit-acp-gateway-daemon-1.7.2.json", import.meta.url), "utf8"));

function integrity(bytes) {
  return `sha512-${createHash("sha512").update(bytes).digest("base64")}`;
}

async function lockFor(bytes) {
  const lock = await readGatewayLock();
  return { ...lock, package: { ...lock.package, integrity: integrity(bytes) } };
}

function fetchBytes(bytes, { fail = false, calls } = {}) {
  return async () => {
    if (calls) calls.count += 1;
    if (fail) throw new Error("download interrupted");
    return {
      ok: true,
      status: 200,
      body: {},
      arrayBuffer: async () => bytes
    };
  };
}

async function visibleCacheNames(cacheRoot) {
  return (await readdir(cacheRoot)).filter((name) => !name.startsWith("."));
}

async function withTemp(prefix, run) {
  const root = await mkdtemp(join(tmpdir(), prefix));
  try { await run(root); } finally { await rm(root, { recursive: true, force: true }); }
}

test("a verified download becomes the cache only after the sha512 integrity matches", () => withTemp("agenlynk-fetch-cache-", async (cacheRoot) => {
  const payload = Buffer.from("good-gateway-tarball\n");
  const tarball = await ensureCachedGatewayTarball({ lock: await lockFor(payload), cacheRoot, fetchImpl: fetchBytes(payload) });
  assert.equal(await integrityOfFile(tarball), integrity(payload));
  assert.equal(await readFile(tarball, "utf8"), "good-gateway-tarball\n");
  assert.deepEqual(await visibleCacheNames(cacheRoot), ["acp-gateway-daemon-1.7.2.tgz"]);
}));

test("a valid cache is reused without downloading", () => withTemp("agenlynk-fetch-cache-", async (cacheRoot) => {
  const payload = Buffer.from("good-gateway-tarball\n");
  await writeFile(join(cacheRoot, "acp-gateway-daemon-1.7.2.tgz"), payload);
  const calls = { count: 0 };
  const tarball = await ensureCachedGatewayTarball({
    lock: await lockFor(payload),
    cacheRoot,
    fetchImpl: fetchBytes(Buffer.from("should-not-download\n"), { calls })
  });
  assert.equal(calls.count, 0);
  assert.equal(await readFile(tarball, "utf8"), "good-gateway-tarball\n");
}));

test("a download with the wrong integrity never becomes the cache", () => withTemp("agenlynk-fetch-cache-", async (cacheRoot) => {
  const lock = await lockFor(Buffer.from("good-gateway-tarball\n"));
  await assert.rejects(
    () => ensureCachedGatewayTarball({ lock, cacheRoot, fetchImpl: fetchBytes(Buffer.from("partial-or-corrupt\n")) }),
    /integrity mismatch/
  );
  await assert.rejects(access(join(cacheRoot, "acp-gateway-daemon-1.7.2.tgz")), { code: "ENOENT" });
  assert.deepEqual(await visibleCacheNames(cacheRoot), []);
}));

test("a failed download leaves a previous cache file untouched", () => withTemp("agenlynk-fetch-cache-", async (cacheRoot) => {
  const lock = await lockFor(Buffer.from("good-gateway-tarball\n"));
  await writeFile(join(cacheRoot, "acp-gateway-daemon-1.7.2.tgz"), "stale-corrupt-cache\n");
  await assert.rejects(
    () => ensureCachedGatewayTarball({ lock, cacheRoot, fetchImpl: fetchBytes(Buffer.from("also-bad\n")) }),
    /integrity mismatch/
  );
  assert.equal(await readFile(join(cacheRoot, "acp-gateway-daemon-1.7.2.tgz"), "utf8"), "stale-corrupt-cache\n");
  assert.deepEqual(await visibleCacheNames(cacheRoot), ["acp-gateway-daemon-1.7.2.tgz"]);
}));

test("an interrupted download never creates the cache file", () => withTemp("agenlynk-fetch-cache-", async (cacheRoot) => {
  const payload = Buffer.from("good-gateway-tarball\n");
  const lock = await lockFor(payload);
  await assert.rejects(
    () => ensureCachedGatewayTarball({ lock, cacheRoot, fetchImpl: fetchBytes(payload, { fail: true }) }),
    /download interrupted/
  );
  assert.deepEqual(await visibleCacheNames(cacheRoot), []);
}));

test("tarball listings admit only regular files and directories under package/", () => {
  const line = (type, name) => `${type}rw-r--r--  0 0 0  1 Jan  1  1985 ${name}`;
  assert.doesNotThrow(() => assertTarballListingSafe(
    [line("-", "package/package.json"), line("d", "package/src/")].join("\n"),
    ["package/package.json", "package/src/"]
  ));
  assert.throws(() => assertTarballListingSafe(line("l", "package/escape -> /etc"), ["package/escape"]), /non-file entry/);
  assert.throws(() => assertTarballListingSafe(line("-", "package/../evil"), ["package/../evil"]), /unsafe/);
  assert.throws(() => assertTarballListingSafe(line("-", "other/file"), ["other/file"]), /unexpected Gateway package root/);
  assert.throws(() => assertTarballListingSafe("", []), /unreadable/);
});

test("the published 1.7.2 provenance matches the lock's repository, workflow, tag, commit, and integrity", async () => {
  const lock = await readGatewayLock();
  assert.deepEqual(evaluateProvenance(auditEntry, lock), {
    verified: true,
    predicateType: "https://slsa.dev/provenance/v1",
    repository: "https://github.com/creverse-ai-lab/agent_gateway",
    workflow: ".github/workflows/publish-npm.yml",
    ref: "refs/tags/v1.7.2",
    sourceCommit: "009a5174657d09e471101a5fdc217aa6a2a8698a"
  });
});

test("provenance for another integrity, commit, or workflow is rejected", async () => {
  const lock = await readGatewayLock();
  assert.throws(() => evaluateProvenance(auditEntry, {
    ...lock,
    package: { ...lock.package, integrity: `sha512-${Buffer.alloc(64, 7).toString("base64")}` }
  }), /attested digest is not the pinned integrity/);
  assert.throws(() => evaluateProvenance(auditEntry, { ...lock, sourceCommit: "f".repeat(40) }), /source commit/);
  assert.throws(() => evaluateProvenance(auditEntry, {
    ...lock,
    provenance: { ...lock.provenance, workflow: ".github/workflows/other.yml" }
  }), /not the pinned workflow/);
  assert.throws(() => evaluateProvenance({ ...auditEntry, attestationBundles: [] }, lock), /no verified SLSA provenance/);
  assert.throws(() => evaluateProvenance(undefined, lock), /did not verify the pinned package/);
});

test("a statement naming another repository is rejected by the signing certificate identity", async () => {
  // Even when the (npm-verified) statement and the lock agree on a repository,
  // the certificate is issued to the workflow that really signed it.
  const lock = await readGatewayLock();
  const forged = "https://github.com/someone-else/agent_gateway";
  const entry = structuredClone(auditEntry);
  const bundle = entry.attestationBundles.find((item) => item.predicateType === "https://slsa.dev/provenance/v1").bundle;
  const statement = JSON.parse(Buffer.from(bundle.dsseEnvelope.payload, "base64").toString("utf8"));
  statement.predicate.buildDefinition.externalParameters.workflow.repository = forged;
  bundle.dsseEnvelope.payload = Buffer.from(JSON.stringify(statement)).toString("base64");
  assert.throws(
    () => evaluateProvenance(entry, { ...lock, provenance: { ...lock.provenance, repository: forged } }),
    /signing certificate is not issued to/
  );
});

test("npm provenance verification installs the pinned version and reads npm's verified report", async () => {
  const lock = await readGatewayLock();
  const calls = [];
  const runNpm = (installed, report) => async (args, { cwd }) => {
    calls.push(args.slice(0, 2).join(" "));
    if (args[0] === "install") {
      assert.deepEqual(JSON.parse(await readFile(join(cwd, "package.json"), "utf8")).dependencies, { "acp-gateway-daemon": "1.7.2" });
      await writeFile(join(cwd, "package-lock.json"), JSON.stringify({ packages: { "node_modules/acp-gateway-daemon": installed } }));
      return "";
    }
    return JSON.stringify(report);
  };
  const installed = { version: "1.7.2", resolved: lock.package.tarball, integrity: lock.package.integrity };
  const verified = await verifyGatewayProvenance({ lock, runNpm: runNpm(installed, { invalid: [], missing: [], verified: [auditEntry] }) });
  assert.equal(verified.verified, true);
  assert.deepEqual(calls, ["install --ignore-scripts", "audit signatures"]);

  await assert.rejects(
    verifyGatewayProvenance({ lock, runNpm: runNpm({ ...installed, integrity: "sha512-other" }, { verified: [auditEntry] }) }),
    /resolved a different tarball/
  );
  await assert.rejects(
    verifyGatewayProvenance({ lock, runNpm: runNpm(installed, { invalid: [{ name: "acp-gateway-daemon" }], verified: [] }) }),
    /could not verify/
  );
});

async function packFixture(workspace, { extra } = {}) {
  const packageDir = join(workspace, "src-tree", "package");
  await mkdir(join(packageDir, "gateway-client"), { recursive: true });
  await mkdir(join(packageDir, "src"), { recursive: true });
  await writeFile(join(packageDir, "package.json"), JSON.stringify({
    name: "acp-gateway-daemon",
    version: "1.7.2",
    type: "module",
    exports: { ".": "./gateway-client/index.js", "./client": "./gateway-client/index.js" }
  }));
  await writeFile(join(packageDir, "gateway-client/index.js"), "export const GATEWAY_API_VERSION = 1;\n");
  await writeFile(join(packageDir, "src/index.js"), "export {};\n");
  if (extra) await extra(packageDir);
  const tarball = join(workspace, "acp-gateway-daemon-1.7.2.tgz");
  await execFileAsync("tar", ["-czf", tarball, "-C", join(workspace, "src-tree"), "package"]);
  const lock = await readGatewayLock();
  const lockPath = join(workspace, "gateway.lock.json");
  await writeFile(lockPath, JSON.stringify({ ...lock, package: { ...lock.package, integrity: await integrityOfFile(tarball) } }));
  return { tarball, lockPath };
}

test("fetch unpacks the verified tarball into node_modules with the gateway alias and a package record", () => withTemp("agenlynk-fetch-e2e-", async (workspace) => {
  const { tarball, lockPath } = await packFixture(workspace);
  const outputRoot = join(workspace, "seed");
  await mkdir(join(outputRoot, "app-runtime"), { recursive: true });
  await writeFile(join(outputRoot, "app-runtime/keep.js"), "kept\n");
  const provenance = { verified: true, repository: "stub" };
  const result = await fetchGatewayRuntime({ lockPath, artifactPath: tarball, outputRoot, verifyProvenance: async () => provenance });
  assert.equal(result.provenance, provenance);
  assert.equal(await readlink(join(outputRoot, "gateway")), "node_modules/acp-gateway-daemon");
  assert.ok((await lstat(join(outputRoot, "node_modules/acp-gateway-daemon"))).isDirectory());
  assert.equal(await readFile(join(outputRoot, "gateway/src/index.js"), "utf8"), "export {};\n");
  assert.equal(await readFile(join(outputRoot, "app-runtime/keep.js"), "utf8"), "kept\n");
  const record = JSON.parse(await readFile(join(outputRoot, "gateway-package.json"), "utf8"));
  assert.equal(record.integrity, await integrityOfFile(tarball));
  assert.deepEqual(record.provenance, provenance);
  assert.deepEqual(record.files.map((entry) => entry.path), [
    "gateway-client/",
    "gateway-client/index.js",
    "package.json",
    "src/",
    "src/index.js"
  ]);
  assert.deepEqual((await readdir(outputRoot)).sort(), ["app-runtime", "gateway", "gateway-package.json", "node_modules"]);

  // Refetching replaces the three entries in place.
  await fetchGatewayRuntime({ lockPath, artifactPath: tarball, outputRoot, verifyProvenance: async () => provenance });
  assert.deepEqual((await readdir(outputRoot)).sort(), ["app-runtime", "gateway", "gateway-package.json", "node_modules"]);
}));

test("fetch refuses a tarball whose integrity is not the pinned one, before provenance or unpacking", () => withTemp("agenlynk-fetch-e2e-", async (workspace) => {
  const { tarball } = await packFixture(workspace);
  let asked = false;
  await assert.rejects(fetchGatewayRuntime({
    artifactPath: tarball,
    outputRoot: join(workspace, "seed"),
    verifyProvenance: async () => { asked = true; return { verified: true }; }
  }), /integrity mismatch/);
  assert.equal(asked, false);
  await assert.rejects(access(join(workspace, "seed")), { code: "ENOENT" });
}));

test("fetch refuses a tarball carrying a symlink", () => withTemp("agenlynk-fetch-e2e-", async (workspace) => {
  const { tarball, lockPath } = await packFixture(workspace, { extra: (dir) => symlink("/etc/passwd", join(dir, "escape")) });
  await assert.rejects(
    fetchGatewayRuntime({ lockPath, artifactPath: tarball, outputRoot: join(workspace, "seed"), verifyProvenance: async () => ({ verified: true }) }),
    /non-file entry/
  );
}));

test("a skipped provenance check is recorded as unverified", () => withTemp("agenlynk-fetch-e2e-", async (workspace) => {
  const { tarball, lockPath } = await packFixture(workspace);
  const outputRoot = join(workspace, "seed");
  const result = await fetchGatewayRuntime({ lockPath, artifactPath: tarball, outputRoot, skipProvenance: true });
  assert.equal(result.provenance.verified, false);
  assert.equal(JSON.parse(await readFile(join(outputRoot, "gateway-package.json"), "utf8")).provenance.verified, false);
}));
