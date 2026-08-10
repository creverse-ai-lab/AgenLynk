// Claude Code transcripts (~/.claude/projects/**/*.jsonl).
//
// Claude ships no database, so the transcript is the only source for both the
// session's state and the Gateway workers it launched. Parenthood is taken
// exclusively from `mcpMeta.structuredContent` — a genuine MCP tool result —
// because a transcript is full of untrusted text that may quote acp ids.

import { readdir, stat } from "node:fs/promises";
import { join } from "node:path";
import { reversedRecords } from "./jsonl.js";
import { externalParent, gatewayResponseLinks, linkKey } from "./parent-links.js";

const MAX_SCANNED_RECORDS = 120;
/** A running Claude turn goes stale fast; a finished one lingers briefly. */
const RUNNING_LIFETIME_SECONDS = 30;

export function claudeSignal(record) {
  const kind = record?.type;
  const message = record?.message ?? {};
  const contentTypes = new Set(
    (Array.isArray(message?.content) ? message.content : [])
      .filter((item) => item && typeof item === "object")
      .map((item) => item.type)
  );
  if (kind === "system" && record?.subtype === "turn_duration") return ["ready", "turn_duration"];
  if (kind === "assistant") {
    if (message?.stop_reason === "end_turn") return ["ready", "end_turn"];
    if (contentTypes.has("thinking") || contentTypes.has("text") || contentTypes.has("tool_use")) {
      return ["running", "assistant"];
    }
  }
  if (kind === "user" && (contentTypes.has("text") || contentTypes.has("tool_result"))) {
    return ["running", "user"];
  }
  return null;
}

export function claudeTimestamp(record, fallback) {
  const raw = record?.timestamp;
  if (typeof raw !== "string") return fallback;
  const milliseconds = Date.parse(raw);
  return Number.isFinite(milliseconds) ? milliseconds / 1000 : fallback;
}

/** The newest state signal in a transcript, plus any proven gateway links. */
export async function claudeTranscriptSignal(path, modified, stem) {
  let signal = null;
  const links = [];
  let scanned = 0;
  for await (const record of reversedRecords(path)) {
    scanned += 1;
    const structured = record?.mcpMeta?.structuredContent;
    if (structured && typeof structured === "object" && !Array.isArray(structured)) {
      links.push(...gatewayResponseLinks(structured));
    }
    if (signal === null) {
      const found = claudeSignal(record);
      if (found) {
        signal = {
          state: found[0],
          event: found[1],
          time: claudeTimestamp(record, modified),
          session: record?.sessionId ?? record?.session_id ?? stem,
          cwd: record?.cwd ?? null
        };
      }
    }
    if (signal !== null && scanned >= MAX_SCANNED_RECORDS) break;
  }
  if (!signal) return null;
  return { ...signal, links };
}

async function* transcriptPaths(root) {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) {
      yield* transcriptPaths(path);
    } else if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      yield path;
    }
  }
}

/**
 * `cache` maps transcript path -> { fingerprint, signal }. It is rebuilt from
 * only the paths seen this scan, so deletions drop out and a rewrite misses on
 * the fingerprint.
 */
export async function detectClaudeSessions(root, now, readyAfter, staleAfter, parents = null, cache = new Map()) {
  const states = {};
  const scanned = new Map();
  let sawRoot = false;

  for await (const path of transcriptPaths(root)) {
    sawRoot = true;
    let metadata;
    try {
      metadata = await stat(path, { bigint: true });
    } catch {
      continue;
    }
    const modified = Number(metadata.mtimeNs) / 1e9;
    if (now - modified > staleAfter) continue;
    const fingerprint = [
      metadata.dev, metadata.ino, metadata.mtimeNs, metadata.ctimeNs, metadata.size
    ].join(":");
    const cached = cache.get(path);
    const stem = path.split("/").pop().replace(/\.jsonl$/, "");
    const signal = cached && cached.fingerprint === fingerprint
      ? cached.signal
      : await claudeTranscriptSignal(path, modified, stem);
    scanned.set(path, { fingerprint, signal });
    if (!signal) continue;

    if (parents) {
      for (const [provider, acpSession] of signal.links) {
        // A session cannot be its own parent.
        if (acpSession === signal.session) continue;
        const key = linkKey(provider, acpSession);
        if (parents.get(key)?.[0] !== signal.session) parents.set(key, [signal.session, signal.time]);
      }
    }

    const lifetime = signal.state === "ready" ? readyAfter : Math.min(staleAfter, RUNNING_LIFETIME_SECONDS);
    if (now - signal.time <= lifetime) {
      states[signal.session] = {
        provider: "claude",
        session: signal.session,
        state: signal.state,
        event: signal.event,
        time: signal.time,
        pid: null,
        parent: externalParent(parents ?? new Map(), "claude", signal.session),
        engine: "claude-cli",
        cwd: signal.cwd,
        link_session: signal.session
      };
    }
  }

  cache.clear();
  if (sawRoot) for (const [path, value] of scanned) cache.set(path, value);
  return states;
}
