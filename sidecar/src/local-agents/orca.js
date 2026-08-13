// Orca panes (~/Library/Application Support/Orca/agent-hooks/last-status.json).
//
// Orca publishes a single status file for every pane it drives, so this is the
// one source that needs no transcript scanning at all.

import { readFile } from "node:fs/promises";

const STATE_BY_PAYLOAD = { working: "running", done: "ready" };

export async function detectOrcaSessions(path, now, readyAfter, staleAfter) {
  if (!path) return {};
  let entries;
  try {
    entries = JSON.parse(await readFile(path, "utf8"))?.entries ?? {};
  } catch {
    return {};
  }
  const states = {};
  for (const entry of Object.values(entries)) {
    const payload = entry?.payload ?? {};
    const provider = String(payload?.agentType ?? "").toLowerCase();
    const state = STATE_BY_PAYLOAD[payload?.state];
    const timestamp = (entry?.receivedAt ?? 0) / 1000;
    const session = entry?.providerSession?.id;
    if ((provider !== "claude" && provider !== "grok") || !state || !session) continue;
    const lifetime = state === "ready" ? readyAfter : staleAfter;
    if (now - timestamp > lifetime) continue;
    // "repo::/path" — the pane's worktree id carries the directory after "::".
    const worktree = String(entry?.worktreeId ?? "").split("::").slice(1).join("::");
    states[session] = {
      provider,
      session,
      state,
      event: `orca/${payload.state}`,
      time: timestamp,
      pid: null,
      parent: null,
      engine: `${provider}-cli`,
      cwd: worktree || null,
      link_session: session
    };
  }
  return states;
}
