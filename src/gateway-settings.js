import { readFileSync } from "node:fs";
import { chmod, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

// Every definition carries both languages. `label`/`description` stay English
// (they are also the wire-level fallback), and `labelKo`/`descriptionKo` are
// what the Korean-first UI shows first.
//
// `displayUnit` is presentation metadata only: storage, validation, and the
// whole Gateway runtime keep using raw milliseconds. Each ms setting picks the
// unit that renders its default as a small, readable number, so nobody has to
// count zeros in a text field.
export const GATEWAY_SETTING_DEFINITIONS = Object.freeze([
  numberSetting("gcIntervalMs", "lifecycle", "GC interval", "Background cleanup interval.", "ACP_GATEWAY_GC_INTERVAL_MS", 5 * 60_000, 1_000, "ms", {
    labelKo: "GC 주기",
    descriptionKo: "만료된 기록을 정리하는 백그라운드 작업의 실행 주기입니다.",
    displayUnit: "minutes" // default 5 min
  }),
  numberSetting("idleUnloadMs", "lifecycle", "Idle unload", "Unload resumable idle Workers after this delay. Zero disables it.", "ACP_GATEWAY_IDLE_UNLOAD_MS", 30 * 60_000, 0, "ms", {
    labelKo: "유휴 Worker 언로드",
    descriptionKo: "재개 가능한 유휴 Worker를 이 시간이 지나면 메모리에서 내립니다. 0이면 사용하지 않습니다.",
    displayUnit: "minutes" // default 30 min
  }),
  numberSetting("orphanGraceMs", "lifecycle", "Orphan grace", "Grace period before abandoned active work is cancelled.", "ACP_GATEWAY_ORPHAN_GRACE_MS", 24 * 60 * 60_000, 0, "ms", {
    labelKo: "고아 작업 유예",
    descriptionKo: "요청자가 사라진 진행 중 작업을 취소하기까지 기다리는 유예 시간입니다.",
    displayUnit: "hours" // default 24 h
  }),
  numberSetting("resultRetentionMs", "lifecycle", "Result retention", "How long completed task results are retained.", "ACP_GATEWAY_RESULT_RETENTION_MS", 24 * 60 * 60_000, 0, "ms", {
    labelKo: "결과 보존 기간",
    descriptionKo: "완료된 Task 결과를 보관하는 기간입니다.",
    displayUnit: "hours" // default 24 h
  }),
  numberSetting("inboxRetentionMs", "lifecycle", "Inbox retention", "How long resolved inbox requests are retained.", "ACP_GATEWAY_INBOX_RETENTION_MS", 24 * 60 * 60_000, 0, "ms", {
    labelKo: "Inbox 보존 기간",
    descriptionKo: "응답이 끝난 Inbox 요청을 보관하는 기간입니다.",
    displayUnit: "hours" // default 24 h
  }),
  numberSetting("sessionRetentionMs", "lifecycle", "Session retention", "How long completed session records are retained.", "ACP_GATEWAY_SESSION_RETENTION_MS", 7 * 24 * 60 * 60_000, 0, "ms", {
    labelKo: "세션 보존 기간",
    descriptionKo: "완료된 세션 기록을 보관하는 기간입니다.",
    displayUnit: "days" // default 7 d
  }),

  numberSetting("maxEvents", "resourceLimits", "Events per session", "Maximum in-memory events retained for each session.", "ACP_GATEWAY_MAX_EVENTS", 200, 1, "count", {
    labelKo: "세션당 이벤트 수",
    descriptionKo: "세션마다 메모리에 유지하는 최대 이벤트 개수입니다."
  }),
  numberSetting("maxTextBytes", "resourceLimits", "Session text", "Maximum retained session text before spill/trim behavior.", "ACP_GATEWAY_MAX_TEXT_BYTES", 1_000_000, 1, "bytes", {
    labelKo: "세션 텍스트 크기",
    descriptionKo: "세션 텍스트를 잘라내거나 파일로 내보내기 전까지 유지하는 최대 크기입니다."
  }),
  numberSetting("maxInlineResultBytes", "resourceLimits", "Inline result", "Maximum result bytes returned inline before using an artifact.", "ACP_GATEWAY_MAX_INLINE_RESULT_BYTES", 64 * 1024, 1, "bytes", {
    labelKo: "인라인 결과 크기",
    descriptionKo: "Artifact로 저장하지 않고 응답에 그대로 담는 결과의 최대 크기입니다."
  }),
  numberSetting("maxArtifactBytes", "resourceLimits", "Artifact file", "Maximum bytes allowed for one artifact.", "ACP_GATEWAY_MAX_ARTIFACT_BYTES", 100 * 1024 * 1024, 1, "bytes", {
    labelKo: "Artifact 파일 크기",
    descriptionKo: "Artifact 하나에 허용되는 최대 크기입니다."
  }),
  numberSetting("maxArtifactTotalBytes", "resourceLimits", "Artifact storage", "Maximum total artifact storage managed by Gateway.", "ACP_GATEWAY_MAX_ARTIFACT_TOTAL_BYTES", 512 * 1024 * 1024, 1, "bytes", {
    labelKo: "Artifact 전체 용량",
    descriptionKo: "Gateway가 관리하는 Artifact 저장소의 최대 총 용량입니다."
  }),
  numberSetting("artifactSessionLimit", "resourceLimits", "Artifact sessions", "Keep artifacts for this many most-recent sessions; older sessions' artifacts are removed even before the retention period ends.", "ACP_GATEWAY_ARTIFACT_SESSION_LIMIT", 10, 1, "count", {
    labelKo: "Artifact 보관 세션 수",
    descriptionKo: "최근 이 개수만큼의 세션에 대해서만 Artifact를 보관합니다. 더 오래된 세션의 Artifact는 보존 기간이 남아 있어도 삭제됩니다."
  }),
  numberSetting("maxTerminalsPerSession", "resourceLimits", "Terminals per session", "Maximum retained terminal handles for a Worker session.", "ACP_GATEWAY_MAX_TERMINALS_PER_SESSION", 16, 1, "count", {
    labelKo: "세션당 터미널 수",
    descriptionKo: "Worker 세션 하나가 유지할 수 있는 최대 터미널 핸들 개수입니다."
  }),
  numberSetting("maxPendingRequestsPerSession", "resourceLimits", "Pending requests", "Maximum concurrent unanswered Worker requests per session.", "ACP_GATEWAY_MAX_PENDING_REQUESTS_PER_SESSION", 64, 1, "count", {
    labelKo: "미응답 요청 수",
    descriptionKo: "세션당 동시에 응답을 기다릴 수 있는 Worker 요청의 최대 개수입니다."
  }),
  numberSetting("maxFrameBytes", "resourceLimits", "RPC frame", "Maximum bytes accepted in one Gateway NDJSON frame.", "ACP_GATEWAY_MAX_FRAME_BYTES", 32 * 1024 * 1024, 1024, "bytes", {
    labelKo: "RPC 프레임 크기",
    descriptionKo: "Gateway NDJSON 프레임 하나에 허용되는 최대 크기입니다."
  }),

  booleanSetting("workerThoughtStream", "workers", "Worker thinking", "Ask Claude Workers to stream their reasoning. Recent models omit thinking text unless it is requested, so delegated thoughts are otherwise never recorded.", "ACP_GATEWAY_WORKER_THOUGHT_STREAM", true, {
    labelKo: "Worker 사고 과정",
    descriptionKo: "Claude Worker에게 추론 과정을 스트리밍하도록 요청합니다. 최신 모델은 요청하지 않으면 사고 텍스트를 보내지 않으므로, 끄면 위임된 사고 과정이 전혀 기록되지 않습니다."
  }),
  booleanSetting("workerSubagentTranscript", "workers", "Subagent transcripts", "Collect the full transcript (messages, tools, thinking) of Task subagents a Claude Worker spawns internally. Substantially increases event volume per delegation.", "ACP_GATEWAY_WORKER_SUBAGENT_TRANSCRIPT", false, {
    labelKo: "서브에이전트 대화 기록",
    descriptionKo: "Claude Worker가 내부적으로 실행한 Task 서브에이전트의 전체 기록(메시지·도구 호출·사고 과정)을 수집합니다. 위임 한 건당 이벤트 양이 크게 늘어납니다."
  }),

  booleanSetting("localScannerEnabled", "monitor", "Local scanner", "Detect locally started Codex, Claude, and Grok sessions.", "ACP_MONITOR_LOCAL_SCANNER", true, {
    labelKo: "로컬 스캐너",
    descriptionKo: "로컬에서 직접 시작한 Codex·Claude·Grok 세션을 감지합니다."
  }),
  numberSetting("localScanIntervalMs", "monitor", "Local scan interval", "How often the monitor polls known local session files. Lower values make status appear sooner but use more CPU.", "ACP_MONITOR_LOCAL_SCAN_INTERVAL_MS", 1_000, 250, "ms", {
    labelKo: "로컬 스캔 주기",
    descriptionKo: "이미 알고 있는 로컬 세션 파일을 다시 확인하는 주기입니다. 값이 작을수록 상태가 빨리 반영되지만 CPU를 더 사용합니다.",
    displayUnit: "seconds" // default 1 s
  }),
  numberSetting("localDiscoveryIntervalMs", "monitor", "Local discovery interval", "How often the monitor looks for newly created local sessions. Lower values make new sessions appear sooner but perform more filesystem work.", "ACP_MONITOR_LOCAL_DISCOVERY_INTERVAL_MS", 2_000, 500, "ms", {
    labelKo: "로컬 탐색 주기",
    descriptionKo: "새로 만들어진 로컬 세션을 찾는 주기입니다. 값이 작을수록 새 세션이 빨리 나타나지만 파일 검사가 늘어납니다.",
    displayUnit: "seconds" // default 2 s
  }),
  numberSetting("localTranscriptWindowMs", "monitor", "Local transcript window", "How much recent local transcript history to retain for the timeline. Lower values reduce memory use.", "ACP_MONITOR_LOCAL_TRANSCRIPT_WINDOW_MS", 65 * 60_000, 60_000, "ms", {
    labelKo: "로컬 대화 기록 범위",
    descriptionKo: "타임라인에 유지할 최근 로컬 대화 기록의 시간 범위입니다. 값이 작을수록 메모리를 적게 사용합니다.",
    displayUnit: "minutes" // default 65 min
  }),
  numberSetting("localTranscriptRecordLimit", "monitor", "Local transcript records", "Maximum retained local transcript records per session. Lower values reduce memory use.", "ACP_MONITOR_LOCAL_TRANSCRIPT_RECORD_LIMIT", 4_000, 100, "count", {
    labelKo: "로컬 대화 기록 수",
    descriptionKo: "세션당 유지할 로컬 대화 기록의 최대 개수입니다. 값이 작을수록 메모리를 적게 사용합니다."
  }),

  booleanSetting("agentAutoUpdate", "agentUpdates", "Automatic adapter updates", "Automatically apply safe ACP adapter upgrades.", "ACP_GATEWAY_AGENT_AUTO_UPDATE", true, {
    labelKo: "어댑터 자동 업데이트",
    descriptionKo: "안전한 ACP 어댑터 업그레이드를 자동으로 적용합니다."
  }),
  booleanSetting("agentUpdateNotifications", "agentUpdates", "Update notifications", "Expose adapter and Gateway update alerts in health responses.", "ACP_GATEWAY_AGENT_UPDATE_NOTIFICATIONS", true, {
    labelKo: "업데이트 알림",
    descriptionKo: "어댑터와 Gateway 업데이트 알림을 health 응답에 노출합니다."
  }),
  numberSetting("agentUpdateIntervalMs", "agentUpdates", "Update check interval", "Interval between ACP registry and Gateway source checks.", "ACP_GATEWAY_AGENT_UPDATE_INTERVAL_MS", 24 * 60 * 60_000, 5 * 60_000, "ms", {
    labelKo: "업데이트 확인 주기",
    descriptionKo: "ACP 레지스트리와 Gateway 소스를 확인하는 주기입니다.",
    displayUnit: "hours" // default 24 h
  })
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
      labelKo: definition.labelKo,
      description: definition.description,
      descriptionKo: definition.descriptionKo,
      unit: definition.unit ?? null,
      // Storage unit stays `unit` (ms); `displayUnit` only tells a client which
      // scale to render and edit in.
      displayUnit: definition.displayUnit ?? null,
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
  state.gatewayConfig ??= {};
  for (const group of ["lifecycle", "resourceLimits", "workers", "monitor"]) state.gatewayConfig[group] ??= {};
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

function numberSetting(id, group, label, description, environment, defaultValue, minimum, unit, text = {}) {
  return {
    id,
    group,
    label,
    labelKo: text.labelKo ?? label,
    description,
    descriptionKo: text.descriptionKo ?? description,
    environment,
    defaultValue,
    minimum,
    unit,
    displayUnit: text.displayUnit ?? null,
    type: "number"
  };
}

function booleanSetting(id, group, label, description, environment, defaultValue, text = {}) {
  return {
    id,
    group,
    label,
    labelKo: text.labelKo ?? label,
    description,
    descriptionKo: text.descriptionKo ?? description,
    environment,
    defaultValue,
    displayUnit: null,
    type: "boolean"
  };
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
