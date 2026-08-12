import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { access, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createInterface } from "node:readline";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { readFile } from "node:fs/promises";
import { GatewayRpcClient } from "../src/socket-rpc.js";
import { MonitorState } from "../src/monitor-state.js";
import { annotateRuntimeSplit, restartBlockedError } from "../src/monitor.js";

// The Swift half of this contract lives in MonitorModelTests.swift
// (restartBlockersMatchTheSharedGatewayContract) and replays the same file.
// Both sides feed the updater, which refuses to activate on any blocker, so a
// divergence either blocks a safe update or lets an unsafe one through.
test("restartBlockers matches the shared blocker contract the Settings UI also implements", async () => {
  const fixtureUrl = new URL("./fixtures/restart-blockers.json", import.meta.url);
  const { cases } = JSON.parse(await readFile(fixtureUrl, "utf8"));
  assert.ok(cases.length > 0, "fixture must define at least one case");

  for (const { name, sessions, tasks, inbox, expected } of cases) {
    const state = new MonitorState();
    state.setSessions(sessions.map((session) => ({ provider: "codex", cwd: "/tmp/project", ...session })));
    state.tasks = tasks;
    state.inbox = inbox;
    assert.deepEqual(state.restartBlockers(), expected, name);
  }
});

test("restartBlockedError reports the stable monitor_restart_blocked code and the blocker detail", () => {
  const error = restartBlockedError(["진행 중 세션 1개", "미응답 Inbox 1개"]);
  assert.equal(error.statusCode, 409);
  assert.equal(error.code, "monitor_restart_blocked");
  assert.equal(error.message, "Gateway를 안전하게 재시작할 수 없습니다: 진행 중 세션 1개, 미응답 Inbox 1개");

  const withNoBlockers = restartBlockedError([]);
  assert.equal(withNoBlockers.code, "monitor_restart_blocked");
  assert.equal(withNoBlockers.message, "Gateway를 안전하게 재시작할 수 없습니다: ");
});

test("a daemon serving from a different runtime root is flagged as a split brain", () => {
  const monitorRoot = "/Users/x/.acp-gateway/runtime/versions/1.3.1-new";
  const foreign = annotateRuntimeSplit(
    { gatewayVersion: "1.3.1", runtimeRoot: "/Users/x/dev/checkout" },
    monitorRoot
  );
  assert.deepEqual(foreign.runtimeSplit, {
    daemonRuntimeRoot: "/Users/x/dev/checkout",
    monitorRuntimeRoot: monitorRoot
  });

  const same = annotateRuntimeSplit({ runtimeRoot: monitorRoot }, monitorRoot);
  assert.equal(same.runtimeSplit, undefined, "matching roots are not a split");

  // A daemon with neither field proves nothing, and a null setup passes through.
  assert.equal(annotateRuntimeSplit({ gatewayVersion: "1.0.0" }, monitorRoot, "build-a").runtimeSplit, undefined);
  assert.equal(annotateRuntimeSplit(null, monitorRoot), null, "a null setup passes through");

  // Build-id mismatch is a split even without runtimeRoot (old daemons) or
  // with an equal root (a checkout daemon started before a git pull).
  const oldDaemon = annotateRuntimeSplit({ gatewayBuildId: "build-old" }, monitorRoot, "build-new");
  assert.deepEqual(oldDaemon.runtimeSplit, { daemonBuildId: "build-old", monitorBuildId: "build-new" });
  const stalePull = annotateRuntimeSplit(
    { runtimeRoot: monitorRoot, gatewayBuildId: "build-old" }, monitorRoot, "build-new"
  );
  assert.deepEqual(stalePull.runtimeSplit, { daemonBuildId: "build-old", monitorBuildId: "build-new" });
  assert.equal(
    annotateRuntimeSplit({ runtimeRoot: monitorRoot, gatewayBuildId: "build-new" }, monitorRoot, "build-new").runtimeSplit,
    undefined,
    "matching root and build is healthy"
  );
});

test("native monitor controls Gateway config and safely restarts into pending values", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-monitor-control-"));
  const socketPath = join(directory, "gateway.sock");
  const statePath = join(directory, "state.json");
  const installStatePath = join(directory, "install.json");
  const token = "test-control-token-at-least-24-characters";
  const rootId = "main-monitor-test";
  const commonEnv = {
    ...process.env,
    ACP_GATEWAY_SOCKET: socketPath,
    ACP_GATEWAY_STATE: statePath,
    ACP_GATEWAY_INSTALL_STATE: installStatePath,
    ACP_GATEWAY_CONTROL_TOKEN: token,
    ACP_GATEWAY_ROOT_ID: rootId,
    ACP_GATEWAY_DISABLE_DYNAMIC_PROVIDERS: "1"
  };
  await writeFile(installStatePath, JSON.stringify({
    version: 1,
    managedMcp: {},
    identity: { token, rootId },
    agentUpdates: { autoUpdate: true, notifications: true }
  }), { mode: 0o600 });

  const daemon = spawn(process.execPath, [fileURLToPath(new URL("../src/gateway-daemon.js", import.meta.url))], {
    env: commonEnv,
    stdio: ["ignore", "ignore", "pipe"]
  });
  let daemonError = "";
  daemon.stderr.on("data", (chunk) => { daemonError += chunk.toString(); });
  const cleanupRpc = new GatewayRpcClient({ socketPath, token, rootId, autoStart: false });
  let monitor = null;
  try {
    await waitForPath(socketPath, () => daemonError);
    await cleanupRpc.call("setup", {}, 15_000);
    monitor = spawn(process.execPath, [fileURLToPath(new URL("../src/monitor.js", import.meta.url))], {
      env: { ...commonEnv, ACP_GATEWAY_MONITOR_PORT: "0", ACP_GATEWAY_MONITOR_AUTOSTART: "0" },
      stdio: ["ignore", "pipe", "pipe"]
    });
    const lines = createInterface({ input: monitor.stdout });
    const ready = await Promise.race([
      new Promise((resolve, reject) => lines.once("line", (line) => {
        try { resolve(JSON.parse(line)); } catch (error) { reject(error); }
      })),
      new Promise((_, reject) => setTimeout(() => reject(new Error("monitor ready timeout")), 15_000))
    ]);
    const headers = { authorization: `Bearer ${ready.apiToken}` };
    const initial = await fetchJson(`${ready.url}/api/gateway-config`, { headers });
    assert.equal(initial.options.length, 25);

    const staged = await fetchJson(`${ready.url}/api/gateway-config`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: JSON.stringify({ action: "set", values: { maxEvents: 321, agentAutoUpdate: false } })
    });
    const stagedEvents = staged.options.find((option) => option.id === "maxEvents");
    const stagedUpdates = staged.options.find((option) => option.id === "agentAutoUpdate");
    assert.equal(stagedEvents.currentValue, 200);
    assert.equal(stagedEvents.configuredValue, 321);
    assert.equal(stagedEvents.pending, true);
    assert.equal(stagedUpdates.currentValue, false);
    assert.equal(stagedUpdates.pending, false);

    const restarted = await fetchJson(`${ready.url}/api/gateway-restart`, { method: "POST", headers });
    assert.equal(restarted.ok, true);
    const applied = await fetchJson(`${ready.url}/api/gateway-config`, { headers });
    const appliedEvents = applied.options.find((option) => option.id === "maxEvents");
    assert.equal(appliedEvents.currentValue, 321);
    assert.equal(appliedEvents.configuredValue, 321);
    assert.equal(appliedEvents.pending, false);
  } finally {
    if (monitor && monitor.exitCode == null) {
      const exited = once(monitor, "close");
      monitor.kill("SIGTERM");
      await exited;
    }
    try { await cleanupRpc.call("daemon_shutdown", {}, 5_000); } catch {}
    cleanupRpc.close();
    if (daemon.exitCode == null) {
      const exited = once(daemon, "close");
      daemon.kill("SIGTERM");
      await exited;
    }
    await rm(directory, { recursive: true, force: true });
  }
});

test("native monitor cold-starts Gateway when no daemon is running", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-monitor-cold-start-"));
  const socketPath = join(directory, "gateway.sock");
  const statePath = join(directory, "state.json");
  const installStatePath = join(directory, "install.json");
  const token = "test-control-token-at-least-24-characters";
  const rootId = "main-monitor-cold-start";
  const env = {
    ...process.env,
    ACP_GATEWAY_SOCKET: socketPath,
    ACP_GATEWAY_STATE: statePath,
    ACP_GATEWAY_INSTALL_STATE: installStatePath,
    ACP_GATEWAY_CONTROL_TOKEN: token,
    ACP_GATEWAY_ROOT_ID: rootId,
    ACP_GATEWAY_DISABLE_DYNAMIC_PROVIDERS: "1",
    ACP_GATEWAY_MONITOR_PORT: "0",
    ACP_GATEWAY_MONITOR_AUTOSTART: "1"
  };
  await writeFile(installStatePath, JSON.stringify({
    version: 1,
    managedMcp: {},
    identity: { token, rootId },
    agentUpdates: { autoUpdate: true, notifications: true }
  }), { mode: 0o600 });

  const monitor = spawn(process.execPath, [fileURLToPath(new URL("../src/monitor.js", import.meta.url))], {
    env,
    stdio: ["ignore", "pipe", "pipe"]
  });
  const cleanupRpc = new GatewayRpcClient({ socketPath, token, rootId, autoStart: false });
  try {
    const lines = createInterface({ input: monitor.stdout });
    const ready = await Promise.race([
      new Promise((resolve, reject) => lines.once("line", (line) => {
        try { resolve(JSON.parse(line)); } catch (error) { reject(error); }
      })),
      new Promise((_, reject) => setTimeout(() => reject(new Error("cold-start monitor ready timeout")), 15_000))
    ]);
    // `gateway` (setup metadata) is populated by refreshGatewayInfo AFTER the
    // subscription flips connected/streaming, so a snapshot can be
    // connected+streaming with gateway still null. Wait for gateway too, or a
    // slow CI reads the null and NPEs on gatewayVersion.
    const snapshot = await waitForSnapshot(ready.url, { authorization: `Bearer ${ready.apiToken}` },
      (value) => value.connected && value.streaming && value.gateway);
    assert.equal(snapshot.connected, true);
    assert.equal(snapshot.streaming, true);
    assert.equal(snapshot.gateway.gatewayVersion, "1.3.2");
    await access(socketPath);
  } finally {
    if (monitor.exitCode == null) {
      const exited = once(monitor, "close");
      monitor.kill("SIGTERM");
      await exited;
    }
    try { await cleanupRpc.call("daemon_shutdown", {}, 5_000); } catch {}
    cleanupRpc.close();
    await rm(directory, { recursive: true, force: true });
  }
});

test("native monitor exposes /api/meta, versioned snapshot, and stable error codes", async () => {
  const directory = await mkdtemp(join(tmpdir(), "acp-monitor-api-"));
  const socketPath = join(directory, "gateway.sock");
  const token = "test-control-token-at-least-24-characters";
  const rootId = "main-monitor-api-test";
  const env = {
    ...process.env,
    ACP_GATEWAY_SOCKET: socketPath,
    ACP_GATEWAY_CONTROL_TOKEN: token,
    ACP_GATEWAY_ROOT_ID: rootId,
    ACP_GATEWAY_MONITOR_PORT: "0",
    ACP_GATEWAY_MONITOR_AUTOSTART: "0"
  };

  // No Gateway daemon is started for this test: the API-shape and
  // error-code contract must hold even before a "setup" call ever succeeds.
  const monitor = spawn(process.execPath, [fileURLToPath(new URL("../src/monitor.js", import.meta.url))], {
    env,
    stdio: ["ignore", "pipe", "pipe"]
  });
  try {
    const lines = createInterface({ input: monitor.stdout });
    const ready = await Promise.race([
      new Promise((resolve, reject) => lines.once("line", (line) => {
        try { resolve(JSON.parse(line)); } catch (error) { reject(error); }
      })),
      new Promise((_, reject) => setTimeout(() => reject(new Error("monitor ready timeout")), 15_000))
    ]);
    assert.equal(ready.schemaVersion, 1);
    assert.equal(ready.monitorApiVersion, "1.0");
    assert.deepEqual(ready.gatewayIdentity, {
      rootId,
      gatewayApiVersion: null,
      gatewayVersion: null,
      gatewayBuildId: null
    });
    assert.deepEqual(ready.capabilities, {});
    const headers = { authorization: `Bearer ${ready.apiToken}` };

    const meta = await fetchJson(`${ready.url}/api/meta`, { headers });
    assert.equal(meta.schemaVersion, 1);
    assert.equal(meta.monitorApiVersion, "1.0");
    assert.deepEqual(meta.gatewayIdentity, ready.gatewayIdentity);
    assert.deepEqual(meta.capabilities, {});

    const snapshot = await fetchJson(`${ready.url}/api/snapshot`, { headers });
    assert.equal(snapshot.schemaVersion, 1);
    assert.equal(snapshot.monitorApiVersion, "1.0");

    const unauthorized = await fetch(`${ready.url}/api/meta`, { headers: { authorization: "Bearer wrong" } });
    assert.equal(unauthorized.status, 401);
    const unauthorizedBody = await unauthorized.json();
    assert.equal(unauthorizedBody.error, "unauthorized");
    assert.equal(unauthorizedBody.code, "monitor_unauthorized");

    const notFound = await fetch(`${ready.url}/api/does-not-exist`, { headers });
    assert.equal(notFound.status, 404);
    const notFoundBody = await notFound.json();
    assert.equal(notFoundBody.error, "not found");
    assert.equal(notFoundBody.code, "monitor_not_found");

    const malformed = await fetch(`${ready.url}/api/session-config`, {
      method: "POST",
      headers: { ...headers, "content-type": "application/json" },
      body: "not json"
    });
    assert.equal(malformed.status, 500);
    const malformedBody = await malformed.json();
    assert.equal(typeof malformedBody.error, "string");
    assert.equal(malformedBody.code, "monitor_internal");
  } finally {
    if (monitor.exitCode == null) {
      const exited = once(monitor, "close");
      monitor.kill("SIGTERM");
      await exited;
    }
    await rm(directory, { recursive: true, force: true });
  }
});

async function fetchJson(url, options) {
  const response = await fetch(url, options);
  const body = await response.json();
  if (!response.ok) throw new Error(body.error ?? `HTTP ${response.status}`);
  return body;
}

async function waitForSnapshot(baseURL, headers, predicate) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const snapshot = await fetchJson(`${baseURL}/api/snapshot`, { headers });
    if (predicate(snapshot)) return snapshot;
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error("monitor snapshot did not become ready");
}

async function waitForPath(path, errorDetail = () => "") {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    try {
      await access(path);
      return;
    } catch (error) {
      if (error?.code !== "ENOENT") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error(`path did not appear: ${path}${errorDetail() ? `\n${errorDetail()}` : ""}`);
}
