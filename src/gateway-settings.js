import { readFileSync } from "node:fs";
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const GATEWAY_SETTING_DEFINITIONS = Object.freeze([
  numberSetting("gcIntervalMs", "lifecycle", "GC interval", "Background cleanup interval.", "ACP_GATEWAY_GC_INTERVAL_MS", 5 * 60_000, 1_000, "ms"),
  numberSetting("idleUnloadMs", "lifecycle", "Idle unload", "Unload resumable idle Workers after this delay. Zero disables it.", "ACP_GATEWAY_IDLE_UNLOAD_MS", 30 * 60_000, 0, "ms"),
  numberSetting("orphanGraceMs", "lifecycle", "Orphan grace", "Grace period before abandoned active work is cancelled.", "ACP_GATEWAY_ORPHAN_GRACE_MS", 24 * 60 * 60_000, 0, "ms"),
  numberSetting("resultRetentionMs", "lifecycle", "Result retention", "How long completed task results are retained.", "ACP_GATEWAY_RESULT_RETENTION_MS", 24 * 60 * 60_000, 0, "ms"),
  numberSetting("inboxRetentionMs", "lifecycle", "Inbox retention", "How long resolved inbox requests are retained.", "ACP_GATEWAY_INBOX_RETENTION_MS", 24 * 60 * 60_000, 0, "ms"),
  numberSetting("sessionRetentionMs", "lifecycle", "Session retention", "How long completed session records are retained.", "ACP_GATEWAY_SESSION_RETENTION_MS", 7 * 24 * 60 * 60_000, 0, "ms"),

  numberSetting("maxEvents", "resourceLimits", "Events per session", "Maximum in-memory events retained for each session.", "ACP_GATEWAY_MAX_EVENTS", 200, 1, "count"),
  numberSetting("maxTextBytes", "resourceLimits", "Session text", "Maximum retained session text before spill/trim behavior.", "ACP_GATEWAY_MAX_TEXT_BYTES", 1_000_000, 1, "bytes"),
  numberSetting("maxInlineResultBytes", "resourceLimits", "Inline result", "Maximum result bytes returned inline before using an artifact.", "ACP_GATEWAY_MAX_INLINE_RESULT_BYTES", 64 * 1024, 1, "bytes"),
  numberSetting("maxArtifactBytes", "resourceLimits", "Artifact file", "Maximum bytes allowed for one artifact.", "ACP_GATEWAY_MAX_ARTIFACT_BYTES", 100 * 1024 * 1024, 1, "bytes"),
  numberSetting("maxArtifactTotalBytes", "resourceLimits", "Artifact storage", "Maximum total artifact storage managed by Gateway.", "ACP_GATEWAY_MAX_ARTIFACT_TOTAL_BYTES", 512 * 1024 * 1024, 1, "bytes"),
  numberSetting("maxTerminalsPerSession", "resourceLimits", "Terminals per session", "Maximum retained terminal handles for a Worker session.", "ACP_GATEWAY_MAX_TERMINALS_PER_SESSION", 16, 1, "count"),
  numberSetting("maxPendingRequestsPerSession", "resourceLimits", "Pending requests", "Maximum concurrent unanswered Worker requests per session.", "ACP_GATEWAY_MAX_PENDING_REQUESTS_PER_SESSION", 64, 1, "count"),
  numberSetting("maxFrameBytes", "resourceLimits", "RPC frame", "Maximum bytes accepted in one Gateway NDJSON frame.", "ACP_GATEWAY_MAX_FRAME_BYTES", 32 * 1024 * 1024, 1024, "bytes"),

  booleanSetting("agentAutoUpdate", "agentUpdates", "Automatic adapter updates", "Automatically apply safe ACP adapter upgrades.", "ACP_GATEWAY_AGENT_AUTO_UPDATE", true),
  booleanSetting("agentUpdateNotifications", "agentUpdates", "Update notifications", "Expose adapter and Gateway update alerts in health responses.", "ACP_GATEWAY_AGENT_UPDATE_NOTIFICATIONS", true),
  numberSetting("agentUpdateIntervalMs", "agentUpdates", "Update check interval", "Interval between ACP registry and Gateway source checks.", "ACP_GATEWAY_AGENT_UPDATE_INTERVAL_MS", 24 * 60 * 60_000, 5 * 60_000, "ms")
]);

const DEFINITIONS_BY_ID = new Map(GATEWAY_SETTING_DEFINITIONS.map((definition) => [definition.id, definition]));

export function defaultGatewayInstallStatePath() {
  return process.env.ACP_GATEWAY_INSTALL_STATE || join(homedir(), ".acp-gateway", "install.json");
}

export function resolveGatewaySettings({ statePath = defaultGatewayInstallStatePath(), env = process.env } = {}) {
  const state = readStateSync(statePath);
  return Object.fromEntries(GATEWAY_SETTING_DEFINITIONS.map((definition) => [
    definition.id,
    resolveDefinition(definition, state, env).effectiveValue
  ]));
}

export function defaultGatewaySettings({ env = process.env } = {}) {
  return Object.fromEntries(GATEWAY_SETTING_DEFINITIONS.map((definition) => [
    definition.id,
    resolveDefinition(definition, {}, env).effectiveValue
  ]));
}

export function gatewaySettingsSnapshot({
  statePath = defaultGatewayInstallStatePath(),
  env = process.env,
  activeValues = null
} = {}) {
  const state = readStateSync(statePath);
  const options = GATEWAY_SETTING_DEFINITIONS.map((definition) => {
    const resolved = resolveDefinition(definition, state, env);
    const activeValue = activeValues && Object.hasOwn(activeValues, definition.id)
      ? activeValues[definition.id]
      : resolved.effectiveValue;
    return {
      id: definition.id,
      group: definition.group,
      type: definition.type,
      label: definition.label,
      description: definition.description,
      unit: definition.unit ?? null,
      minimum: definition.minimum ?? null,
      defaultValue: definition.defaultValue,
      currentValue: activeValue,
      configuredValue: resolved.effectiveValue,
      storedValue: resolved.storedValue,
      source: resolved.source,
      environment: definition.environment,
      editable: resolved.source !== "environment",
      requiresRestart: definition.group !== "agentUpdates",
      pending: activeValue !== resolved.effectiveValue
    };
  });
  return {
    ok: true,
    options,
    pendingRestart: options.some((option) => option.pending && option.requiresRestart),
    pendingLiveApply: options.some((option) => option.pending && !option.requiresRestart)
  };
}

export async function updateGatewaySettings({
  statePath = defaultGatewayInstallStatePath(),
  env = process.env,
  values = {},
  resetIds = []
} = {}) {
  if (!values || typeof values !== "object" || Array.isArray(values)) throw new Error("values must be an object");
  if (!Array.isArray(resetIds)) throw new Error("resetIds must be an array");
  const ids = new Set([...Object.keys(values), ...resetIds]);
  for (const id of ids) {
    const definition = DEFINITIONS_BY_ID.get(id);
    if (!definition) throw new Error(`Unknown Gateway config option: ${id}`);
    if (env[definition.environment] != null && env[definition.environment] !== "") {
      throw new Error(`${id} is locked by ${definition.environment}`);
    }
  }

  const state = await readState(statePath);
  validateInstallState(state, statePath);
  if (state.version !== 1) {
    throw new Error("ACP Gateway must be installed before changing settings");
  }
  state.gatewayConfig ??= { lifecycle: {}, resourceLimits: {} };
  state.gatewayConfig.lifecycle ??= {};
  state.gatewayConfig.resourceLimits ??= {};
  state.agentUpdates ??= { autoUpdate: true, notifications: true };

  for (const [id, value] of Object.entries(values)) {
    const definition = DEFINITIONS_BY_ID.get(id);
    setStoredValue(state, definition, validateValue(definition, value));
  }
  for (const id of resetIds) deleteStoredValue(state, DEFINITIONS_BY_ID.get(id));
  validateCrossFieldSettings(state, env);
  state.updatedAt = new Date().toISOString();
  await writeState(statePath, state);
  return gatewaySettingsSnapshot({ statePath, env });
}

function numberSetting(id, group, label, description, environment, defaultValue, minimum, unit) {
  return { id, group, label, description, environment, defaultValue, minimum, unit, type: "number" };
}

function booleanSetting(id, group, label, description, environment, defaultValue) {
  return { id, group, label, description, environment, defaultValue, type: "boolean" };
}

function resolveDefinition(definition, state, env) {
  const environmentValue = env[definition.environment];
  const storedValue = getStoredValue(state, definition);
  if (environmentValue != null && environmentValue !== "") {
    return {
      effectiveValue: parseEnvironmentValue(definition, environmentValue),
      storedValue,
      source: "environment"
    };
  }
  if (storedValue != null) {
    return { effectiveValue: validateValue(definition, storedValue), storedValue, source: "stored" };
  }
  return { effectiveValue: definition.defaultValue, storedValue: null, source: "default" };
}

function parseEnvironmentValue(definition, raw) {
  if (definition.type === "boolean") {
    const normalized = String(raw).toLowerCase();
    if (["1", "true", "on", "yes"].includes(normalized)) return true;
    if (["0", "false", "off", "no"].includes(normalized)) return false;
    throw new Error(`${definition.environment} must be on or off`);
  }
  const value = Number(raw);
  if (!Number.isFinite(value) || value < definition.minimum) {
    throw new Error(`${definition.environment} must be a number >= ${definition.minimum}`);
  }
  return value;
}

function validateValue(definition, value) {
  if (definition.type === "boolean") {
    if (typeof value !== "boolean") throw new Error(`${definition.id} must be true or false`);
    return value;
  }
  if (!Number.isSafeInteger(value) || value < definition.minimum) {
    throw new Error(`${definition.id} must be an integer >= ${definition.minimum}`);
  }
  return value;
}

function getStoredValue(state, definition) {
  if (definition.group === "agentUpdates") {
    const key = agentUpdateStorageKey(definition.id);
    return state?.agentUpdates?.[key] ?? null;
  }
  return state?.gatewayConfig?.[definition.group]?.[definition.id] ?? null;
}

function setStoredValue(state, definition, value) {
  if (definition.group === "agentUpdates") {
    state.agentUpdates[agentUpdateStorageKey(definition.id)] = value;
    return;
  }
  state.gatewayConfig[definition.group][definition.id] = value;
}

function deleteStoredValue(state, definition) {
  if (definition.group === "agentUpdates") {
    delete state.agentUpdates[agentUpdateStorageKey(definition.id)];
    return;
  }
  delete state.gatewayConfig?.[definition.group]?.[definition.id];
}

function agentUpdateStorageKey(id) {
  return {
    agentAutoUpdate: "autoUpdate",
    agentUpdateNotifications: "notifications",
    agentUpdateIntervalMs: "intervalMs"
  }[id];
}

function validateCrossFieldSettings(state, env) {
  const values = resolveGatewaySettingsFromState(state, env);
  if (values.maxArtifactTotalBytes < values.maxArtifactBytes) {
    throw new Error("maxArtifactTotalBytes must be greater than or equal to maxArtifactBytes");
  }
}

function resolveGatewaySettingsFromState(state, env) {
  return Object.fromEntries(GATEWAY_SETTING_DEFINITIONS.map((definition) => [
    definition.id,
    resolveDefinition(definition, state, env).effectiveValue
  ]));
}

function readStateSync(path) {
  try {
    const state = JSON.parse(readFileSync(path, "utf8"));
    validateInstallState(state, path);
    return state;
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw new Error(`Cannot read Gateway settings ${path}: ${error.message}`);
  }
}

async function readState(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"));
  } catch (error) {
    if (error?.code === "ENOENT") return {};
    throw new Error(`Cannot read Gateway settings ${path}: ${error.message}`);
  }
}

function validateInstallState(state, path) {
  if (!state || typeof state !== "object" || Array.isArray(state)) throw new Error(`Invalid install state at ${path}`);
  if (Object.keys(state).length && state.version !== 1) throw new Error(`Unsupported install state version at ${path}`);
}

async function writeState(path, state) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, path);
  await chmod(path, 0o600);
}
