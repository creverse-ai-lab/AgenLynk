// Attribution of Gateway workers to the local session that launched them.
//
// The security property here matters more than the plumbing: a session that
// merely *mentions* an acp id — because it printed gateway output while
// debugging, or read the gateway's own state file — must never claim
// parenthood of that worker. Only proven gateway tool RESPONSES count.

const ACP_LINK_PATTERN = /"acpSessionId"\s*:\s*"([^"]+)"/g;
const ACP_PROVIDER_PATTERN = /"provider"\s*:\s*"([a-z0-9_-]+)"/;
const ACP_RESPONSE_PATTERN = /"ok"\s*:\s*true/;
const LINK_WINDOW = 400;

/** Map key for a (provider, session) pair. */
export function linkKey(provider, session) {
  return `${provider}\u0000${session}`;
}

export function splitLinkKey(key) {
  const [provider, session] = key.split("\u0000");
  return { provider, session };
}

/**
 * (provider, acpSessionId) pairs from an unescaped record dump. A match only
 * counts when a provider and an `"ok":true` marker sit within the same window,
 * i.e. the text really is a gateway response body.
 */
export function claudeAcpLinks(text) {
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
 * Links from a payload the log itself marked as a gateway tool result.
 * Callers must only pass proven structured content.
 */
export function gatewayResponseLinks(payload) {
  return claudeAcpLinks(JSON.stringify(payload).replaceAll('\\"', '"'));
}

/**
 * Records parenthood from a Codex `mcp_tool_call_end` record. The MCP server
 * name is the proof this is a gateway call rather than quoted text.
 */
export function recordExternalParent(record, parent, parents, now) {
  const payload = record?.payload ?? {};
  if (record?.type !== "event_msg" || payload?.type !== "mcp_tool_call_end") return false;
  let changed = false;
  const resultText = JSON.stringify(payload?.result ?? {});
  const server = String(payload?.invocation?.server ?? "").toLowerCase();

  // Gateway responses (server named e.g. "agent-acp") carry the worker provider
  // inline, so the provider comes from the response body, not the server name.
  if (server.includes("acp")) {
    for (const [provider, session] of claudeAcpLinks(resultText.replaceAll('\\"', '"'))) {
      const key = linkKey(provider, session);
      if (parents.get(key)?.[0] !== parent) {
        parents.set(key, [parent, now]);
        changed = true;
      }
    }
  }

  const provider = server.includes("claude") ? "claude" : server.includes("grok") ? "grok" : null;
  if (!provider) return changed;
  for (const match of resultText.matchAll(/"(?:sessionId|acpSessionId)"\s*:\s*"([^"]+)"/g)) {
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
