import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { resolveGatewaySettings } from "./gateway-settings.js";

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
  const settings = resolveGatewaySettings();
  return {
    gcIntervalMs: settings.gcIntervalMs,
    idleUnloadMs: settings.idleUnloadMs,
    orphanGraceMs: settings.orphanGraceMs,
    resultRetentionMs: settings.resultRetentionMs,
    inboxRetentionMs: settings.inboxRetentionMs,
    sessionRetentionMs: settings.sessionRetentionMs,
    maxEvents: settings.maxEvents,
    maxTextBytes: settings.maxTextBytes,
    maxInlineResultBytes: settings.maxInlineResultBytes,
    maxArtifactBytes: settings.maxArtifactBytes,
    maxArtifactTotalBytes: settings.maxArtifactTotalBytes,
    maxTerminalsPerSession: settings.maxTerminalsPerSession,
    maxPendingRequestsPerSession: settings.maxPendingRequestsPerSession,
    maxFrameBytes: settings.maxFrameBytes
  };
}

export function gatewayAgentUpdateConfig() {
  const settings = resolveGatewaySettings();
  return {
    enabled: settings.agentAutoUpdate,
    notifications: settings.agentUpdateNotifications,
    intervalMs: settings.agentUpdateIntervalMs
  };
}
