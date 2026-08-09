import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";

const KNOWN_FRONTDOOR_AGENTS = ["claude", "grok", "codex", "cursor", "auggie", "gemini", "windsurf", "zed"];
const SESSION_ENVIRONMENT_KEYS = [
  ["ACP_FRONTDOOR_SESSION_ID", null],
  ["CODEX_THREAD_ID", "codex"],
  ["CODEX_SESSION_ID", "codex"],
  ["CLAUDE_SESSION_ID", "claude"],
  ["CLAUDE_CODE_SESSION_ID", "claude"],
  ["GROK_SESSION_ID", "grok"],
  ["GROK_CONVERSATION_ID", "grok"]
];

export function detectFrontdoorContext({
  env = process.env,
  parentPid = process.ppid,
  processInfo = readProcessInfo(parentPid)
} = {}) {
  const command = `${processInfo.command ?? ""} ${processInfo.comm ?? ""}`.trim().toLowerCase();
  let agent = detectAgent(command);
  let sessionId = null;

  for (const [key, provider] of SESSION_ENVIRONMENT_KEYS) {
    const candidate = validSessionId(env[key]);
    if (!candidate) continue;
    sessionId = candidate;
    agent ??= provider;
    break;
  }
  sessionId ??= sessionIdFromCommand(processInfo.command ?? "");

  const fallback = createHash("sha256")
    .update(`${parentPid}\0${processInfo.startedAt ?? ""}`)
    .digest("base64url")
    .slice(0, 24);
  return {
    agent,
    sessionId,
    instanceId: sessionId ?? `process:${fallback}`
  };
}

export function frontdoorContextForRequest(baseContext, requestMeta) {
  const metadata = requestMetadata(requestMeta);
  const sessionId = firstSessionId(metadata);
  if (!sessionId) return baseContext;
  return {
    ...baseContext,
    agent: metadata.agent ?? baseContext?.agent,
    sessionId,
    instanceId: sessionId
  };
}

export function sessionIdFromCommand(command) {
  const text = String(command ?? "");
  const option = text.match(/(?:^|\s)--(?:resume|session-id|conversation-id)(?:=|\s+)["']?([A-Za-z0-9][A-Za-z0-9._:-]{7,511})/i);
  if (option) return validSessionId(option[1]);
  const resume = text.match(/(?:^|\s)resume\s+["']?([A-Za-z0-9][A-Za-z0-9._:-]{7,511})/i);
  return validSessionId(resume?.[1]);
}

function detectAgent(command) {
  return KNOWN_FRONTDOOR_AGENTS.find((candidate) => command.includes(candidate)) ?? null;
}

function requestMetadata(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) return { values: [], agent: null };
  const candidates = [value];
  for (const [key, nested] of Object.entries(value)) {
    if (!nested || typeof nested !== "object" || Array.isArray(nested)) continue;
    if (/codex/i.test(key)) candidates.unshift(nested);
    else candidates.push(nested);
  }
  const values = [];
  for (const candidate of candidates) {
    for (const key of ["threadId", "thread_id", "sessionId", "session_id", "conversationId", "conversation_id"]) {
      values.push(candidate[key]);
    }
  }
  const keys = Object.keys(value).join(" ").toLowerCase();
  const agent = KNOWN_FRONTDOOR_AGENTS.find((candidate) => keys.includes(candidate))
    ?? (values.some((candidate) => candidate != null) && ("threadId" in value || "thread_id" in value) ? "codex" : null);
  return { values, agent };
}

function firstSessionId(metadata) {
  for (const value of metadata.values) {
    const candidate = validSessionId(value);
    if (candidate) return candidate;
  }
  return null;
}

function validSessionId(value) {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.length > 512 || /[\u0000-\u001f\u007f]/.test(trimmed)) return null;
  return trimmed;
}

function readProcessInfo(parentPid) {
  return {
    comm: runPs(parentPid, "comm="),
    command: runPs(parentPid, "command="),
    startedAt: runPs(parentPid, "lstart=")
  };
}

function runPs(parentPid, field) {
  try {
    return execFileSync("ps", ["-o", field, "-p", String(parentPid)], { timeout: 2_000 })
      .toString()
      .trim();
  } catch {
    return "";
  }
}
