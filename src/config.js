import { homedir, tmpdir } from "node:os";
import { join } from "node:path";

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
    maxTextBytes: numberEnv("ACP_GATEWAY_MAX_TEXT_BYTES", 1_000_000, 1)
  };
}

function numberEnv(name, fallback, minimum) {
  const raw = process.env[name];
  if (raw == null || raw === "") return fallback;
  const value = Number(raw);
  if (!Number.isFinite(value) || value < minimum) throw new Error(`${name} must be a number >= ${minimum}`);
  return value;
}
