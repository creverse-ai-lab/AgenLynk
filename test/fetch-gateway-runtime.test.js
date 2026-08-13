import assert from "node:assert/strict";
import { access, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createHash } from "node:crypto";
import { ensureCachedGatewayArchive, sha256File } from "../scripts/fetch-gateway-runtime.js";

function digest(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function lockFor(bytes) {
  return {
    asset: {
      name: "acp-gateway-runtime-darwin-arm64.tar.gz",
      url: "https://example.invalid/acp-gateway-runtime-darwin-arm64.tar.gz",
      sha256: digest(bytes)
    }
  };
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

test("a verified download becomes the cache only after the SHA matches", async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "agenlynk-fetch-cache-"));
  try {
    const payload = Buffer.from("good-gateway-archive\n");
    const archive = await ensureCachedGatewayArchive({
      lock: lockFor(payload),
      cacheRoot,
      fetchImpl: fetchBytes(payload)
    });
    assert.equal(await sha256File(archive), digest(payload));
    assert.equal(await readFile(archive, "utf8"), "good-gateway-archive\n");
  } finally { await rm(cacheRoot, { recursive: true, force: true }); }
});

test("a valid cache is reused without downloading", async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "agenlynk-fetch-cache-"));
  try {
    const payload = Buffer.from("good-gateway-archive\n");
    const lock = lockFor(payload);
    await mkdir(cacheRoot, { recursive: true });
    await writeFile(join(cacheRoot, lock.asset.name), payload);
    const calls = { count: 0 };
    const archive = await ensureCachedGatewayArchive({
      lock,
      cacheRoot,
      fetchImpl: fetchBytes(Buffer.from("should-not-download\n"), { calls })
    });
    assert.equal(calls.count, 0);
    assert.equal(await readFile(archive, "utf8"), "good-gateway-archive\n");
  } finally { await rm(cacheRoot, { recursive: true, force: true }); }
});

test("a bad SHA download never becomes the cache", async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "agenlynk-fetch-cache-"));
  try {
    const good = Buffer.from("good-gateway-archive\n");
    const bad = Buffer.from("partial-or-corrupt\n");
    const lock = lockFor(good);
    await assert.rejects(
      () => ensureCachedGatewayArchive({ lock, cacheRoot, fetchImpl: fetchBytes(bad) }),
      /SHA-256 mismatch/
    );
    await assert.rejects(access(join(cacheRoot, lock.asset.name)), { code: "ENOENT" });
    assert.deepEqual(await visibleCacheNames(cacheRoot), []);
  } finally { await rm(cacheRoot, { recursive: true, force: true }); }
});

test("a failed download leaves a previous cache file untouched", async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "agenlynk-fetch-cache-"));
  try {
    const good = Buffer.from("good-gateway-archive\n");
    const stale = Buffer.from("stale-corrupt-cache\n");
    const lock = lockFor(good);
    await mkdir(cacheRoot, { recursive: true });
    await writeFile(join(cacheRoot, lock.asset.name), stale);
    await assert.rejects(
      () => ensureCachedGatewayArchive({ lock, cacheRoot, fetchImpl: fetchBytes(Buffer.from("also-bad\n")) }),
      /SHA-256 mismatch/
    );
    assert.equal(await readFile(join(cacheRoot, lock.asset.name), "utf8"), "stale-corrupt-cache\n");
    assert.deepEqual(await visibleCacheNames(cacheRoot), [lock.asset.name]);
  } finally { await rm(cacheRoot, { recursive: true, force: true }); }
});

test("an interrupted download never creates the cache file", async () => {
  const cacheRoot = await mkdtemp(join(tmpdir(), "agenlynk-fetch-cache-"));
  try {
    const payload = Buffer.from("good-gateway-archive\n");
    const lock = lockFor(payload);
    await assert.rejects(
      () => ensureCachedGatewayArchive({ lock, cacheRoot, fetchImpl: fetchBytes(payload, { fail: true }) }),
      /download interrupted/
    );
    await assert.rejects(access(join(cacheRoot, lock.asset.name)), { code: "ENOENT" });
    assert.deepEqual(await visibleCacheNames(cacheRoot), []);
  } finally { await rm(cacheRoot, { recursive: true, force: true }); }
});
