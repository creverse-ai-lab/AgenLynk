import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { readFileSync } from "node:fs";

const uid = typeof process.getuid === "function" ? process.getuid() : "user";

export function gatewaySocketPath() {
  return process.env.ACP_GATEWAY_SOCKET || join(tmpdir(), `acp-gateway-${uid}.sock`);
}

export function gatewayStatePath() {
  return process.env.ACP_GATEWAY_STATE || join(homedir(), ".acp-gateway", "state.json");
}

export function controlToken() {
  const value = process.env.ACP_GATEWAY_CONTROL_TOKEN;
  if (!value || value.length < 24) {
    throw new Error("ACP_GATEWAY_CONTROL_TOKEN must be set to at least 24 characters");
  }
  return value;
}

export function rootId() {
  return process.env.ACP_GATEWAY_ROOT_ID || `main-${process.ppid}`;
}

export function gatewayLifecycleConfig() {
  return {
    gcIntervalMs: numberEnv("ACP_GATEWAY_GC_INTERVAL_MS", 5 * 60_000, 1_000),
    idleUnloadMs: numberEnv("ACP_GATEWAY_IDLE_UNLOAD_MS", 30 * 60_000, 0),
    orphanGraceMs: numberEnv("ACP_GATEWAY_ORPHAN_GRACE_MS", 24 * 60 * 60_000, 0),
    resultRetentionMs: numberEnv("ACP_GATEWAY_RESULT_RETENTION_MS", 24 * 60 * 60_000, 0),
    inboxRetentionMs: numberEnv("ACP_GATEWAY_INBOX_RETENTION_MS", 24 * 60 * 60_000, 0),
    sessionRetentionMs: numberEnv("ACP_GATEWAY_SESSION_RETENTION_MS", 7 * 24 * 60 * 60_000, 0),
    maxEvents: numberEnv("ACP_GATEWAY_MAX_EVENTS", 200, 1),
    maxTextBytes: numberEnv("ACP_GATEWAY_MAX_TEXT_BYTES", 1_000_000, 1),
    maxArtifactBytes: numberEnv("ACP_GATEWAY_MAX_ARTIFACT_BYTES", 100 * 1024 * 1024, 1),
    maxArtifactTotalBytes: numberEnv("ACP_GATEWAY_MAX_ARTIFACT_TOTAL_BYTES", 512 * 1024 * 1024, 1),
    maxTerminalsPerSession: numberEnv("ACP_GATEWAY_MAX_TERMINALS_PER_SESSION", 16, 1),
    maxPendingRequestsPerSession: numberEnv("ACP_GATEWAY_MAX_PENDING_REQUESTS_PER_SESSION", 64, 1),
    maxFrameBytes: numberEnv("ACP_GATEWAY_MAX_FRAME_BYTES", 32 * 1024 * 1024, 1024)
  };
}

export function gatewayAgentUpdateConfig() {
  const policy = readAgentUpdatePolicy();
  const autoUpdate = typeof policy.autoUpdate === "boolean" ? policy.autoUpdate : true;
  const notifications = typeof policy.notifications === "boolean" ? policy.notifications : true;
  return {
    enabled: booleanEnv("ACP_GATEWAY_AGENT_AUTO_UPDATE", autoUpdate),
    notifications: booleanEnv("ACP_GATEWAY_AGENT_UPDATE_NOTIFICATIONS", notifications),
    intervalMs: numberEnv("ACP_GATEWAY_AGENT_UPDATE_INTERVAL_MS", 24 * 60 * 60_000, 5 * 60_000)
  };
}

function readAgentUpdatePolicy() {
  const path = process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
  try {
    const state = JSON.parse(readFileSync(path, "utf8"));
    return state?.agentUpdates && typeof state.agentUpdates === "object" ? state.agentUpdates : {};
  } catch {
    return {};
  }
}

function numberEnv(name, fallback, minimum) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < minimum) throw new Error(`${name} must be a number >= ${minimum}`);
  return value;
}

function booleanEnv(name, fallback) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  if (["1", "true", "on", "yes"].includes(raw.toLowerCase())) return true;
  if (["0", "false", "off", "no"].includes(raw.toLowerCase())) return false;
  throw new Error(`${name} must be on or off`);
}
