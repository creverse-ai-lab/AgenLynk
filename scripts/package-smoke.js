#!/usr/bin/env node

import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { readManifestFile, verifyRuntimeManifest } from "../src/runtime-manifest.js";

const app = resolve(process.argv[2] || "build/AgenLynk.app");
const resources = join(app, "Contents/Resources");
const seed = join(resources, "gateway-seed");
const gateway = join(seed, "gateway");
const sidecar = join(resources, "sidecar");
const node = join(seed, "node/bin/node");

assert.notEqual(gateway, sidecar);
await access(join(gateway, "src/gateway-daemon.js"));
await access(join(gateway, "gateway-client/index.js"));
await access(join(sidecar, "src/server/monitor.js"));
await verifyRuntimeManifest(seed, await readManifestFile(seed));

const temporary = await mkdtemp(join(tmpdir(), "agenlynk-package-smoke-"));
const socketPath = join(temporary, "gateway.sock");
const installState = join(temporary, "install.json");
const token = "package-smoke-control-token-123456789";
const rootId = "package-smoke-root";
await writeFile(installState, JSON.stringify({ version: 1, identity: { token, rootId }, managedMcp: {} }));

const common = {
  ...process.env,
  ACP_GATEWAY_SOCKET: socketPath,
  ACP_GATEWAY_STATE: join(temporary, "state.json"),
  ACP_GATEWAY_INSTALL_STATE: installState,
  ACP_GATEWAY_ARTIFACTS: join(temporary, "artifacts"),
  ACP_GATEWAY_CONTROL_TOKEN: token,
  ACP_GATEWAY_ROOT_ID: rootId,
  ACP_GATEWAY_NODE: node,
  ACP_GATEWAY_CLIENT_ENTRYPOINT: join(gateway, "gateway-client/index.js"),
  ACP_GATEWAY_ACTIVE_ROOT: gateway,
  ACP_GATEWAY_DISABLE_DYNAMIC_PROVIDERS: "1"
};

let daemon;
let monitor;
try {
  daemon = spawn(node, [join(gateway, "src/gateway-daemon.js")], { env: common, stdio: ["ignore", "ignore", "pipe"] });
  let daemonError = "";
  daemon.stderr.on("data", (chunk) => { daemonError += chunk; });
  await waitFor(async () => {
    if (daemon.exitCode != null) throw new Error(`Gateway daemon exited (${daemon.exitCode}): ${daemonError}`);
    try { await access(socketPath); return true; } catch { return false; }
  }, "Gateway daemon did not create its socket");

  monitor = spawn(node, ["--disable-warning=ExperimentalWarning", join(sidecar, "src/server/monitor.js")], {
    env: { ...common, ACP_GATEWAY_MONITOR_PORT: "0", ACP_GATEWAY_MONITOR_AUTOSTART: "0" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const ready = await waitForReady(monitor);
  assert.equal(ready.kind, "monitor_ready");
  assert.equal(ready.sidecarVersion, "0.4.1");
  const headers = { authorization: `Bearer ${ready.apiToken}` };
  const meta = await waitFor(async () => {
    const response = await fetch(`${ready.url}/api/meta`, { headers });
    const value = await response.json();
    return value.capabilities?.gatewayCompatibility?.status === "supported" ? value : false;
  }, "sidecar did not decode the Gateway 1.4.0 setup contract");
  assert.equal(meta.gatewayIdentity.gatewayVersion, "1.4.0");

  const firstSnapshot = await fetch(`${ready.url}/api/snapshot`, { headers });
  assert.equal(firstSnapshot.status, 200);
  const tag = firstSnapshot.headers.get("etag");
  assert.match(tag ?? "", /^"monitor-\d+"$/);
  const snapshot = await firstSnapshot.json();
  assert.equal(snapshot.connected, true);
  assert.equal(snapshot.streaming, true);
  assert.equal(snapshot.streamHealth, "healthy");
  const unchanged = await fetch(`${ready.url}/api/snapshot`, {
    headers: { ...headers, "if-none-match": tag }
  });
  assert.equal(unchanged.status, 304);

  const streamAbort = new AbortController();
  const stream = await fetch(`${ready.url}/api/stream`, { headers, signal: streamAbort.signal });
  assert.equal(stream.status, 200);
  assert.match(stream.headers.get("content-type") ?? "", /^text\/event-stream/);
  streamAbort.abort();
  process.stdout.write(`package smoke: Gateway 1.4.0 setup/snapshot/SSE and sidecar isolated roots verified (${gateway}, ${sidecar})\n`);
} finally {
  for (const child of [monitor, daemon]) {
    if (!child || child.exitCode != null) continue;
    child.kill("SIGTERM");
    await new Promise((resolveExit) => child.once("exit", resolveExit));
  }
  await rm(temporary, { recursive: true, force: true });
}

async function waitFor(predicate, message) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const result = await predicate();
    if (result) return result;
    await new Promise((resolveWait) => setTimeout(resolveWait, 25));
  }
  throw new Error(message);
}

async function waitForReady(child) {
  const lines = createInterface({ input: child.stdout });
  return new Promise((resolveReady, reject) => {
    const timer = setTimeout(() => reject(new Error("sidecar did not announce monitor_ready")), 10_000);
    lines.on("line", (line) => {
      let value;
      try { value = JSON.parse(line); } catch { return; }
      if (value.kind !== "monitor_ready") return;
      clearTimeout(timer);
      lines.close();
      resolveReady(value);
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`sidecar exited before ready (${code})`));
    });
  });
}
