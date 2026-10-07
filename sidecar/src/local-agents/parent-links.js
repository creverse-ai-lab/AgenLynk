// Attribution of Gateway workers to the local session that launched them.
//
// The security property here matters more than the plumbing: a session that
// merely *mentions* an acp id — because it printed gateway output while
// debugging, or read the gateway's own state file — must never claim
// parenthood of that worker. Only proven gateway tool RESPONSES count.

const ACP_LINK_PATTERN = /"acpSessionId"\s*:\s*"([^"]+)"/g;
const ACP_PROVIDER_PATTERN = /"provider"\s*:\s*"([a-z0-9_-]+)"/;
const ACP_RESPONSE_PATTERN = /"ok"\s*:\s*true/;
const PROVIDER_ID = /^[a-z0-9_-]+$/;
const LINK_WINDOW = 400;
// Gateway text nests JSON in strings (an MCP result's content[].text); a
// response never goes deeper than a few levels of that.
const MAX_LINK_DEPTH = 24;

/** Map key for a (provider, session) pair. */
export function linkKey(provider, session) {
  return `${provider}\u0000${session}`;
}

/**
 * (provider, acpSessionId) pairs from an unescaped text dump that is not JSON.
 * A match only counts when a provider and an `"ok":true` marker sit within the
 * same window, i.e. the text really is a gateway response body.
 */
function textAcpLinks(text) {
  const links = [];
  ACP_LINK_PATTERN.lastIndex = 0;
  let match = ACP_LINK_PATTERN.exec(text);
  while (match !== null) {
    const start = Math.max(0, match.index - LINK_WINDOW);
    const window = text.slice(start, match.index + match[0].length + LINK_WINDOW);
    const provider = ACP_PROVIDER_PATTERN.exec(window);
    if (provider && ACP_RESPONSE_PATTERN.test(window)) links.push([provider[1], match[1]]);
    match = ACP_LINK_PATTERN.exec(text);
  }
  return links;
}

/**
 * (provider, acpSessionId) pairs from a gateway response, read as JSON: each
 * pair is one object's own `acpSessionId` and `provider`, under an
 * `"ok": true` response. Taking the first `"provider"` near an id instead
 * picked up a neighbour's in a session list, or the nested
 * `openedBy.provider` of the Main that opened it. JSON carried in strings is
 * parsed in place; text that is not JSON falls back to the window match.
 * Callers must only pass proven gateway tool output.
 */
export function gatewayResponseLinks(payload) {
  const links = [];
  const walk = (node, confirmed, depth) => {
    if (depth > MAX_LINK_DEPTH) return;
    if (typeof node === "string") {
      if (!node.includes("acpSessionId")) return;
      const text = node.trim();
      if (text.startsWith("{") || text.startsWith("[")) {
        let parsed;
        try {
          parsed = JSON.parse(text);
        } catch {
          parsed = undefined;
        }
        if (parsed !== undefined) {
          walk(parsed, confirmed, depth + 1);
          return;
        }
      }
      links.push(...textAcpLinks(node.replaceAll('\\"', '"')));
      return;
    }
    if (Array.isArray(node)) {
      for (const item of node) walk(item, confirmed, depth + 1);
      return;
    }
    if (!node || typeof node !== "object") return;
    const ok = confirmed || node.ok === true;
    if (ok && typeof node.acpSessionId === "string" && node.acpSessionId
      && typeof node.provider === "string" && PROVIDER_ID.test(node.provider)) {
      // The Main that opened it, when the response says (a session list
      // shows other Mains' workers too).
      const opener = typeof node.openedBy?.sessionId === "string" && node.openedBy.sessionId ? node.openedBy.sessionId : null;
      links.push(opener ? [node.provider, node.acpSessionId, opener] : [node.provider, node.acpSessionId]);
    }
    for (const child of Object.values(node)) walk(child, ok, depth + 1);
  };
  walk(payload, false, 0);
  return links;
}

/**
 * The server and result of a finished Codex MCP call, in either rollout
 * format: `mcp_tool_call_end` (older CLIs) or an `item_completed` event whose
 * item is an `McpToolCall` (current CLI and desktop app, including calls made
 * from code mode's `exec`).
 */
function finishedMcpCall(record) {
  const payload = record?.payload ?? {};
  if (record?.type !== "event_msg") return null;
  if (payload.type === "mcp_tool_call_end") {
    return { server: payload.invocation?.server, result: payload.result };
  }
  if (payload.type === "item_completed" && payload.item?.type === "McpToolCall" && payload.item.status === "completed") {
    return { server: payload.item.server, result: payload.item.result };
  }
  return null;
}

/**
 * Records parenthood from a finished Codex MCP call. The MCP server name is
 * the proof this is a gateway call rather than quoted text.
 */
export function recordExternalParent(record, parent, parents, now) {
  const call = finishedMcpCall(record);
  if (!call) return false;
  let changed = false;
  const server = String(call.server ?? "").toLowerCase();
  // Ids that belong to another Main: its own session id, and the workers it
  // opened. The id scan below must not pick them back up.
  const foreign = new Set();

  // Gateway responses (server named e.g. "agent-acp") carry the worker provider
  // inline, so the provider comes from the response body, not the server name.
  if (server.includes("acp")) {
    for (const [provider, session, opener] of gatewayResponseLinks(call.result ?? {})) {
      // Listing a worker another Main opened does not make it ours.
      if (opener && opener !== parent) {
        foreign.add(session);
        foreign.add(opener);
        continue;
      }
      const key = linkKey(provider, session);
      if (parents.get(key)?.[0] !== parent) {
        parents.set(key, [parent, now]);
        changed = true;
      }
    }
  }

  const provider = server.includes("claude") ? "claude" : server.includes("grok") ? "grok" : null;
  if (!provider) return changed;
  // Serialized only for a server whose result is read.
  const resultText = JSON.stringify(call.result ?? {});
  for (const match of resultText.matchAll(/"(?:sessionId|acpSessionId)"\s*:\s*"([^"]+)"/g)) {
    if (foreign.has(match[1])) continue;
    const key = linkKey(provider, match[1]);
    if (parents.get(key)?.[0] !== parent) {
      parents.set(key, [parent, now]);
      changed = true;
    }
  }
  return changed;
}

export function externalParent(parents, provider, session) {
  return parents.get(linkKey(provider, session))?.[0] ?? null;
}

/** Drops links whose worker is no longer active and whose record went stale. */
export function pruneExternalParents(parents, activeStates, staleAfter, now) {
  let changed = false;
  const activeLinks = new Set();
  for (const item of Object.values(activeStates)) {
    if (item.provider === "claude" || item.provider === "grok") {
      activeLinks.add(linkKey(item.provider, item.link_session ?? item.session));
    }
  }
  for (const [key, [, timestamp]] of [...parents]) {
    if (!activeLinks.has(key) && now - timestamp > staleAfter) {
      parents.delete(key);
      changed = true;
    }
  }
  return changed;
}
