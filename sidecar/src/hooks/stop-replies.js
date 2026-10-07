// Notch replies to a Frontdoor that just finished a turn.
//
// A Frontdoor's Stop hook is the one moment a reply can still reach the live
// conversation: Claude Code, Codex and Grok all accept a Stop hook answer of
// {"decision":"block","reason":...} and carry on with the reason as the next
// instruction. So for an eligible Stop the sidecar holds the hook open for a
// short window, the app shows the alert with a reply box, and the answer
// (or nothing) goes back to the hook. Everything here fails open: no app, a
// timeout or a dismissal all release the agent to stop normally.

import { randomUUID } from "node:crypto";

export const REPLY_WINDOW_MS = 20_000;
// Typing in the box keeps the agent waiting this long from the Stop, at most.
export const REPLY_MAX_WINDOW_MS = 140_000;
const MAX_REPLY_CHARS = 8_000;
const MAX_PREVIEW_CHARS = 600;

export function isStopPayload(payload) {
  return payload?.hook_event_name === "Stop" || payload?.hookEventName === "stop";
}

/**
 * A Stop that ends the Frontdoor's own turn. A Stop carrying an agent id is a
 * sub-agent finishing inside a turn that is still going (see
 * normalize/hook.js; Grok's agentId is its session's own): holding it would
 * freeze that turn, and a reply would go to the sub-agent.
 */
export function isFrontdoorStop(provider, payload) {
  return isStopPayload(payload) && (provider === "grok" || !(payload?.agent_id ?? payload?.agentId));
}

/** What the hook prints so the agent continues with the reply. */
export function stopReplyDecision(text) {
  return JSON.stringify({
    decision: "block",
    reason: `사용자가 AgenLynk 노치에서 답장했습니다:\n${text}`
  });
}

function preview(payload) {
  const text = payload?.last_assistant_message ?? payload?.lastAssistantMessage;
  if (typeof text !== "string") return null;
  const trimmed = text.trim();
  return trimmed.length > MAX_PREVIEW_CHARS ? `${trimmed.slice(0, MAX_PREVIEW_CHARS)}…` : trimmed;
}

export class StopReplies {
  constructor({ windowMs = REPLY_WINDOW_MS, maxWindowMs = REPLY_MAX_WINDOW_MS, now = Date.now } = {}) {
    this.windowMs = windowMs;
    this.maxWindowMs = maxWindowMs;
    this.now = now;
    this.enabled = true;
    this.slots = new Map();
  }

  /**
   * Opens a reply slot and resolves with the reply text, or null when the
   * window closes, the user dismisses it, or the slot is replaced.
   */
  open({ provider, sessionId, cwd = null, payload = null, backgroundTasks = 0 }) {
    // One slot per session: a newer Stop supersedes an unanswered one.
    for (const slot of this.slots.values()) {
      if (slot.public.sessionId === sessionId) this.#close(slot.public.id, null);
    }
    const id = randomUUID();
    const openedAt = this.now();
    const record = {
      public: {
        id, provider, sessionId, cwd,
        lastMessage: preview(payload),
        // Work the turn left running; the notch says so instead of "done".
        backgroundTasks,
        openedAt,
        expiresAt: openedAt + this.windowMs
      },
      resolve: null,
      timer: null
    };
    const reply = new Promise((resolve) => { record.resolve = resolve; });
    this.slots.set(id, record);
    this.#arm(record);
    return { slot: record.public, reply };
  }

  answer(id, text) {
    if (typeof text !== "string" || !text.trim()) throw new Error("text is required");
    if (text.length > MAX_REPLY_CHARS) throw new Error(`text is longer than ${MAX_REPLY_CHARS} characters`);
    return this.#close(id, text.trim());
  }

  dismiss(id) {
    return this.#close(id, null);
  }

  /** The user is typing (sent repeatedly): a fresh window from now, up to the hard cap from the Stop. */
  extend(id) {
    const record = this.slots.get(id);
    if (!record) return null;
    const cap = record.public.openedAt + this.maxWindowMs;
    record.public.expiresAt = Math.min(cap, Math.max(record.public.expiresAt, this.now() + this.windowMs));
    this.#arm(record);
    return record.public;
  }

  list() {
    return [...this.slots.values()].map((record) => record.public);
  }

  closeAll() {
    for (const id of [...this.slots.keys()]) this.#close(id, null);
  }

  #arm(record) {
    clearTimeout(record.timer);
    record.timer = setTimeout(() => this.#close(record.public.id, null), Math.max(0, record.public.expiresAt - this.now()));
    record.timer.unref?.();
  }

  #close(id, text) {
    const record = this.slots.get(id);
    if (!record) return false;
    this.slots.delete(id);
    clearTimeout(record.timer);
    record.resolve(text);
    return true;
  }
}
