#!/usr/bin/env node

import { timingSafeEqual } from "node:crypto";
import { chmod, open, readFile, unlink } from "node:fs/promises";
import { createConnection, createServer } from "node:net";
import { controlToken, gatewayAgentUpdateConfig, gatewayLifecycleConfig, gatewaySocketPath, gatewayStatePath } from "./config.js";
import { AgentUpdateManager } from "./agent-updates.js";
import { checkGatewaySource } from "./gateway-source-monitor.js";
import { GatewayService } from "./gateway-service.js";
import { readNdjson } from "./ndjson.js";
import { createSocketSender } from "./socket-flow.js";
import { GATEWAY_BUILD_ID, GATEWAY_VERSION } from "./version.js";
import {
  gatewaySettingsSnapshot,
  resolveGatewaySettings,
  updateGatewaySettings
} from "./gateway-settings.js";

const socketPath = gatewaySocketPath();
const expectedToken = controlToken();
const expectedRootId = process.env.ACP_GATEWAY_ROOT_ID || null;
const gatewayConfig = gatewayLifecycleConfig();
const agentUpdateConfig = gatewayAgentUpdateConfig();
const agentUpdateManager = new AgentUpdateManager({ ...agentUpdateConfig, sourceChecker: checkGatewaySource });
const service = new GatewayService({ statePath: gatewayStatePath(), agentUpdateManager, ...gatewayConfig });
const activeGatewayValues = {
  ...gatewayConfig,
  agentAutoUpdate: agentUpdateConfig.enabled,
  agentUpdateNotifications: agentUpdateConfig.notifications,
  agentUpdateIntervalMs: agentUpdateConfig.intervalMs
};
const clients = new Set();
let shutdownPromise = null;
const daemonLock = await acquireDaemonLock(socketPath);
try {
  await service.init();
  await removeStaleSocket(socketPath);
} catch (error) {
  await releaseDaemonLock(daemonLock);
  throw error;
}

const server = createServer((socket) => {
  clients.add(socket);
  socket.once("close", () => clients.delete(socket));
  const subscriptions = new Set();
  let boundRootId = null;
  let boundAccess = null;
  const sender = createSocketSender(socket, {
    unsubscribe: (subscriptionId) => service.unsubscribe(subscriptionId, { rootId: boundRootId }),
    removeSubscription: (subscriptionId) => subscriptions.delete(subscriptionId)
  });
  const { send, sendEvent } = sender;
  readNdjson(socket, {
    maxLineBytes: gatewayConfig.maxFrameBytes,
    onOverflow: () => socket.destroy(),
    onLine: async (line) => {
      let request;
      try {
        request = JSON.parse(line);
        const isGuide = request.method === "guide";
        if (!isGuide) {
          if (!tokenMatches(request.token, expectedToken)) throw new Error("Control access denied");
          if (typeof request.rootId !== "string" || !request.rootId) throw new Error("rootId is required");
          if (expectedRootId && request.rootId !== expectedRootId) throw new Error("Control root identity mismatch");
          if (boundRootId && request.rootId !== boundRootId) throw new Error("Socket is already bound to another Main");
          const access = request.access ?? "control";
          if (!new Set(["control", "observer"]).has(access)) throw new Error(`Unknown Gateway access mode: ${access}`);
          if (boundAccess && access !== boundAccess) throw new Error("Socket is already bound to another access mode");
          if (!boundRootId) {
            boundRootId = request.rootId;
            boundAccess = access;
            if (boundAccess === "control") service.attachRoot(boundRootId);
          }
          if (boundAccess === "observer") assertObserverRequest(request);
        }
        if (request.method === "gateway_config") {
          const action = request.args?.action ?? "get";
          if (["get", "list"].includes(action)) {
            send({ id: request.id, ok: true, result: gatewaySettingsSnapshot({ activeValues: activeGatewayValues }) });
            return;
          }
          if (!new Set(["set", "reset"]).has(action)) throw new Error(`Unknown gateway_config action: ${action}`);
          await updateGatewaySettings({
            values: action === "set" ? request.args?.values ?? {} : {},
            resetIds: action === "reset" ? request.args?.ids ?? [] : []
          });
          const resolved = resolveGatewaySettings();
          agentUpdateManager.reconfigure({
            enabled: resolved.agentAutoUpdate,
            notifications: resolved.agentUpdateNotifications,
            intervalMs: resolved.agentUpdateIntervalMs
          });
          activeGatewayValues.agentAutoUpdate = resolved.agentAutoUpdate;
          activeGatewayValues.agentUpdateNotifications = resolved.agentUpdateNotifications;
          activeGatewayValues.agentUpdateIntervalMs = resolved.agentUpdateIntervalMs;
          send({ id: request.id, ok: true, result: gatewaySettingsSnapshot({ activeValues: activeGatewayValues }) });
          return;
        }
        if (request.method === "daemon_shutdown") {
          send({ id: request.id, ok: true, result: {
            ok: true,
            pid: process.pid,
            version: GATEWAY_VERSION,
            buildId: GATEWAY_BUILD_ID
          } });
          setImmediate(() => void shutdown().finally(() => process.exit(0)));
          return;
        }
        if (request.method === "subscribe") {
          const result = service.subscribe(request.args, {
            rootId: request.rootId,
            observer: boundAccess === "observer"
          }, (event) => {
            sendEvent(result.subscriptionId, event);
          });
          subscriptions.add(result.subscriptionId);
          send({ id: request.id, ok: true, result });
          return;
        }
        if (request.method === "unsubscribe") {
          const result = service.unsubscribe(request.args?.subscriptionId, {
            rootId: request.rootId,
            observer: boundAccess === "observer"
          });
          subscriptions.delete(request.args?.subscriptionId);
          send({ id: request.id, ok: true, result });
          return;
        }
        const result = isGuide ? await service.guide() : await service.call(request.method, request.args, {
          rootId: request.rootId,
          observer: boundAccess === "observer"
        });
        send({ id: request.id, ok: true, result });
      } catch (error) {
        if (!socket.destroyed) send({ id: request?.id ?? null, ok: false, error: error?.message ?? String(error) });
      }
    }
  });
  socket.once("close", () => {
    service.removeSubscriptions(subscriptions);
    if (boundRootId && boundAccess === "control") service.detachRoot(boundRootId);
  });
});

try {
  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(socketPath, resolve);
  });
  await chmod(socketPath, 0o600);
} catch (error) {
  await releaseDaemonLock(daemonLock);
  throw error;
}

async function shutdown() {
  if (shutdownPromise) return shutdownPromise;
  shutdownPromise = (async () => {
    for (const socket of clients) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
    await service.shutdown();
    await unlink(socketPath).catch(() => {});
    await releaseDaemonLock(daemonLock);
  })();
  return shutdownPromise;
}

process.once("SIGTERM", () => void shutdown().finally(() => process.exit(0)));
process.once("SIGINT", () => void shutdown().finally(() => process.exit(0)));

function tokenMatches(actual, expected) {
  if (typeof actual !== "string") return false;
  const left = Buffer.from(actual);
  const right = Buffer.from(expected);
  return left.length === right.length && timingSafeEqual(left, right);
}

function assertObserverRequest(request) {
  const method = request.method;
  const args = request.args ?? {};
  if (["subscribe", "unsubscribe", "poll", "watch", "task_get", "task_list", "task_result"].includes(method)) return;
  if (method === "setup" && args.provider == null && args.refreshAgentUpdates !== true) return;
  if (method === "config" && args.action === "list") return;
  if (method === "gateway_config" && ["get", "list"].includes(args.action ?? "get")) return;
  if (method === "session" && ["list", "get"].includes(args.action)) return;
  if (method === "inbox" && ["list", "get"].includes(args.action)) return;
  throw new Error(`Observer access is read-only: ${method}`);
}

async function removeStaleSocket(path) {
  const alive = await new Promise((resolve) => {
    const socket = createConnection(path);
    socket.once("connect", () => {
      socket.end();
      resolve(true);
    });
    socket.once("error", () => resolve(false));
  });
  if (alive) throw new Error(`Gateway is already running at ${path}`);
  await unlink(path).catch((error) => {
    if (error?.code !== "ENOENT") throw error;
  });
}

async function acquireDaemonLock(path) {
  const lockPath = `${path}.lock`;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const handle = await open(lockPath, "wx", 0o600);
      await handle.writeFile(`${process.pid}\n`);
      return { handle, path: lockPath, pid: process.pid };
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
      const ownerPid = Number((await readFile(lockPath, "utf8").catch(() => "")).trim());
      if (Number.isInteger(ownerPid) && processIsAlive(ownerPid)) {
        throw new Error(`Gateway is already starting or running at ${path} (pid=${ownerPid})`);
      }
      await unlink(lockPath).catch((unlinkError) => {
        if (unlinkError?.code !== "ENOENT") throw unlinkError;
      });
    }
  }
  throw new Error(`Could not acquire Gateway daemon lock at ${lockPath}`);
}

async function releaseDaemonLock(lock) {
  await lock.handle.close().catch(() => {});
  const ownerPid = Number((await readFile(lock.path, "utf8").catch(() => "")).trim());
  if (ownerPid === lock.pid) await unlink(lock.path).catch(() => {});
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error?.code === "EPERM";
  }
}
