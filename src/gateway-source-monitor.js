import { execFile } from "node:child_process";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { GATEWAY_VERSION } from "./version.js";

const sourceRoot = dirname(dirname(fileURLToPath(import.meta.url)));

export async function checkGatewaySource({
  root = sourceRoot,
  run = runGit,
  fetchImpl = globalThis.fetch,
  now = () => Date.now()
} = {}) {
  const origin = (await run(root, ["config", "--get", "remote.origin.url"])).trim();
  const repository = githubRepository(origin);
  if (!repository) {
    return {
      status: "unsupported",
      currentVersion: GATEWAY_VERSION,
      mainVersion: null,
      updateAvailable: false,
      checkedAt: new Date(now()).toISOString()
    };
  }
  const document = await fetchJson(
    `https://raw.githubusercontent.com/${repository}/main/package.json`,
    fetchImpl
  );
  if (typeof document.version !== "string") throw new Error("remote main package version is missing");
  return {
    status: "ready",
    currentVersion: GATEWAY_VERSION,
    mainVersion: document.version,
    updateAvailable: isNewerVersion(document.version, GATEWAY_VERSION),
    repository,
    url: `https://github.com/${repository}`,
    checkedAt: new Date(now()).toISOString()
  };
}

function githubRepository(origin) {
  const match = /^(?:https:\/\/github\.com\/|git@github\.com:)([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+?)(?:\.git)?$/.exec(origin);
  return match?.[1] ?? null;
}

function isNewerVersion(candidate, current) {
  const left = parseVersion(candidate);
  const right = parseVersion(current);
  if (!left || !right) return false;
  for (let index = 0; index < 3; index += 1) {
    if (left[index] > right[index]) return true;
    if (left[index] < right[index]) return false;
  }
  return false;
}

async function fetchJson(url, fetchImpl) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15_000);
  timer.unref?.();
  try {
    const response = await fetchImpl(url, { signal: controller.signal, redirect: "follow" });
    if (!response.ok) throw new Error(`remote main version returned HTTP ${response.status}`);
    const text = await response.text();
    if (Buffer.byteLength(text) > 256 * 1024) throw new Error("remote main package document is too large");
    return JSON.parse(text);
  } finally {
    clearTimeout(timer);
  }
}

function parseVersion(value) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)$/.exec(String(value));
  return match ? match.slice(1).map(Number) : null;
}

function runGit(root, args) {
  return new Promise((resolve, reject) => {
    execFile("git", args, { cwd: root, encoding: "utf8", timeout: 10_000 }, (error, stdout) => {
      if (error) reject(error);
      else resolve(stdout);
    });
  });
}
