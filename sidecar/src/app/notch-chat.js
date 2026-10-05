// Notch chat: the app talks to a Worker session through the Gateway, so a
// chat runs on whatever login the provider's CLI already has (a subscription,
// not an API key). These helpers validate what the app sends and shape the
// Gateway calls; the HTTP routes in server/monitor.js only wire them up.

import { homedir } from "node:os";

export const CHAT_PROVIDERS = Object.freeze(["claude", "codex", "grok"]);
const PERMISSION_POLICIES = new Set(["read_only", "ask", "auto_approve"]);
const MAX_PROMPT_CHARS = 32_000;
export const CHAT_POLL_MAX_WAIT_MS = 25_000;

function requireText(value, name) {
  if (typeof value !== "string" || !value.trim()) throw new Error(`${name} is required`);
  return value;
}

const CALLER_ID = /^[A-Za-z0-9._:-]{1,128}$/;

/**
 * The Frontdoor a notch chat is opened for. ACP Gateway's rule is that every
 * Worker belongs to a top-level Frontdoor; the notch only opens one on a
 * Frontdoor's behalf. `monitorSessionId` is the Frontdoor's monitor id
 * ("local:<provider>:<session>").
 */
export function chatFrontdoor(body = {}) {
  const match = typeof body.frontdoor === "string" ? body.frontdoor.match(/^local:(claude|codex|grok):(.+)$/) : null;
  if (!match || !CALLER_ID.test(match[2])) throw new Error("frontdoor must be a local Frontdoor session id");
  return { provider: match[1], sessionId: match[2], monitorSessionId: body.frontdoor };
}

export function chatOpenArgs(body = {}) {
  const provider = requireText(body.provider, "provider");
  if (!CHAT_PROVIDERS.includes(provider)) throw new Error(`provider must be one of: ${CHAT_PROVIDERS.join(", ")}`);
  const permissionPolicy = body.permissionPolicy ?? "ask";
  if (!PERMISSION_POLICIES.has(permissionPolicy)) throw new Error("permissionPolicy must be read_only, ask or auto_approve");
  const args = {
    provider,
    cwd: typeof body.cwd === "string" && body.cwd.trim() ? body.cwd : homedir(),
    permissionPolicy
  };
  if (typeof body.model === "string" && body.model.trim()) args.model = body.model;
  return args;
}

export function chatPromptArgs(body = {}) {
  const sessionId = requireText(body.sessionId, "sessionId");
  const text = requireText(body.text, "text");
  if (text.length > MAX_PROMPT_CHARS) throw new Error(`text is longer than ${MAX_PROMPT_CHARS} characters`);
  return { sessionId, prompt: text };
}

export function chatPollArgs(searchParams) {
  const sessionId = requireText(searchParams.get("sessionId"), "sessionId");
  const cursor = Number(searchParams.get("cursor") ?? 0);
  const waitMs = Number(searchParams.get("waitMs") ?? 0);
  return {
    sessionId,
    cursor: Number.isSafeInteger(cursor) && cursor >= 0 ? cursor : 0,
    waitMs: Number.isFinite(waitMs) ? Math.min(CHAT_POLL_MAX_WAIT_MS, Math.max(0, waitMs)) : 0,
    // The running turn's text so far, so the bubble fills in as it streams.
    includeResult: true,
    // Tool calls feed the one-line "what is it doing" ticker.
    includeToolEvents: true,
    responseProfile: "compact"
  };
}

export function chatPermissionArgs(body = {}) {
  const sessionId = requireText(body.sessionId, "sessionId");
  const requestId = Number(body.requestId);
  if (!Number.isSafeInteger(requestId)) throw new Error("requestId is required");
  return { sessionId, requestId, optionId: typeof body.optionId === "string" ? body.optionId : null };
}

export function chatCancelArgs(body = {}) {
  return { sessionId: requireText(body.sessionId, "sessionId") };
}
