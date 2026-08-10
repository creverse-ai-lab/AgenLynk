const CONTROL_ENVIRONMENT_KEYS = [
  "ACP_GATEWAY_CONTROL_TOKEN",
  "ACP_GATEWAY_ROOT_ID",
  "ACP_GATEWAY_SOCKET"
];

const FRONTDOOR_SESSION_KEYS = new Set([
  "ACP_FRONTDOOR_SESSION_ID",
  "CODEX_THREAD_ID",
  "CODEX_SESSION_ID",
  "CLAUDE_SESSION_ID",
  "CLAUDE_CODE_SESSION_ID",
  "GROK_SESSION_ID",
  "GROK_CONVERSATION_ID"
]);

export const ACP_PROCESS_ROLE = "ACP_GATEWAY_PROCESS_ROLE";

export function delegatedWorkerEnvironment(source = process.env, overrides = {}) {
  const env = withRuntimeSearchPath(stripFrontdoorEnvironment({ ...source, ...overrides }));
  env[ACP_PROCESS_ROLE] = "worker";
  return env;
}

export function gatewayDaemonEnvironment(source = process.env, overrides = {}) {
  const env = stripFrontdoorEnvironment(source);
  delete env[ACP_PROCESS_ROLE];
  return withRuntimeSearchPath({ ...env, ...overrides });
}

export function isDelegatedWorkerEnvironment(env = process.env) {
  return env[ACP_PROCESS_ROLE] === "worker";
}

export function stripFrontdoorEnvironment(source = process.env) {
  const env = { ...source };
  for (const key of CONTROL_ENVIRONMENT_KEYS) delete env[key];
  for (const key of Object.keys(env)) {
    if (FRONTDOOR_SESSION_KEYS.has(key) || isProviderSessionKey(key)) delete env[key];
  }
  return env;
}

function isProviderSessionKey(key) {
  return /^(?:CODEX|CLAUDE|CLAUDE_CODE|GROK)_(?:THREAD|SESSION|CONVERSATION)_ID$/.test(key);
}

function withRuntimeSearchPath(source) {
  const env = { ...source };
  const npmPrefix = env.NPM_CONFIG_PREFIX;
  const candidates = [
    env.ACP_GATEWAY_RUNTIME_BIN,
    typeof npmPrefix === "string" && npmPrefix ? `${npmPrefix}/bin` : null,
    ...(env.PATH ?? "").split(":")
  ].filter(Boolean);
  env.PATH = [...new Set(candidates)].join(":");
  return env;
}
