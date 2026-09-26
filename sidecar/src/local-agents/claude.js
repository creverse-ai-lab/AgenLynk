// Claude Code transcripts (~/.claude/projects/<project>/<session>.jsonl and
// <project>/<session>/subagents/agent-*.jsonl).
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
// The link-recovery pass reads at most this much of a transcript's tail. A
// worker opened further back than that is still known from the worker
// ledger (MonitorState.formerWorkerIds), which survives restarts.
const LINK_SCAN_BYTES = 16 * 1024 * 1024;
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
    // Distinguished so the scanner can keep a long-running tool call alive.
    if (contentTypes.has("tool_use")) return ["running", "tool_use"];
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

/**
 * The newest state signal in a transcript, plus any proven gateway links.
 *
 * Task subagent records share the parent's `sessionId` and are told apart only
 * by `isSidechain`/`agentId`. Keying their signal by `agentId` (with the
 * parent recorded) keeps them from overwriting the parent session's state.
 *
 * `collectAllLinks` scans far past the recent-record budget for gateway
 * links. The in-memory parents map dies with the process, and on the first
 * read of a transcript the link records may sit far behind a long turn —
 * without this pass, every worker opened before a monitor restart would come
 * back as a parentless false Frontdoor. The pass stops after LINK_SCAN_BYTES
 * of the file's tail so a restart does not parse every large transcript.
 */
export async function claudeTranscriptSignal(path, modified, stem, { collectAllLinks = false } = {}) {
  let signal = null;
  const links = [];
  let scanned = 0;
  for await (const record of reversedRecords(path, collectAllLinks ? { maxBytes: LINK_SCAN_BYTES } : {})) {
    scanned += 1;
    const structured = record?.mcpMeta?.structuredContent;
    if (structured && typeof structured === "object" && !Array.isArray(structured)) {
      links.push(...gatewayResponseLinks(structured));
    }
    if (signal === null) {
      const found = claudeSignal(record);
      if (found) {
        const sessionId = record?.sessionId ?? record?.session_id ?? stem;
        const agentId = record?.isSidechain === true && typeof record?.agentId === "string" && record.agentId
          ? record.agentId
          : null;
        if (record?.isSidechain === true && !agentId) {
          // Legacy interleaved sidechain record with no agent identity: child
          // activity must not pose as the main line's state.
        } else {
          signal = {
            state: found[0],
            event: found[1],
            time: claudeTimestamp(record, modified),
            session: agentId ?? sessionId,
            parent: agentId ? sessionId : null,
            cwd: record?.cwd ?? null
          };
        }
      }
    }
    if (!collectAllLinks && signal !== null && scanned >= MAX_SCANNED_RECORDS) break;
  }
  if (!signal) return null;
  return { ...signal, links };
}

async function directoryEntries(root) {
  try {
    return await readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }
}

async function* subagentTranscriptPaths(sessionDirectory) {
  const subagents = join(sessionDirectory, "subagents");
  for (const entry of await directoryEntries(subagents)) {
    if (entry.isFile() && entry.name.startsWith("agent-") && entry.name.endsWith(".jsonl")) {
      yield join(subagents, entry.name);
    }
  }
}

async function* projectTranscriptPaths(projectRoot, entries = null) {
  const projectEntries = entries ?? await directoryEntries(projectRoot);
  for (const entry of projectEntries) {
    const path = join(projectRoot, entry.name);
    if (entry.isFile() && entry.name.endsWith(".jsonl")) {
      yield path;
    } else if (entry.isDirectory()) {
      // Claude stores nested workers only in this exact location. Do not
      // recurse through tool-results, worktrees, or arbitrary future folders.
      yield* subagentTranscriptPaths(path);
    }
  }
}

async function* transcriptPaths(root) {
  let entries;
  entries = await directoryEntries(root);
  if (!entries.length) return;

  // Tests and custom roots may point directly at one project directory.
  const directTranscripts = entries.some((entry) => entry.isFile() && entry.name.endsWith(".jsonl"));
  if (directTranscripts) {
    yield* projectTranscriptPaths(root, entries);
    return;
  }

  // The normal root contains one directory per project. Only inspect each
  // project's top-level transcripts and exact subagent transcript folder.
  for (const entry of entries) {
    if (entry.isDirectory()) {
      yield* projectTranscriptPaths(join(root, entry.name));
    }
  }
}

/**
 * `cache` maps transcript path -> { fingerprint, signal, modified }.
 *
 * Two modes:
 * - Structured scan (`dirtyPaths` null): enumerate only Claude's documented
 *   top-level and subagent transcript locations, rebuilding the cache from
 *   paths seen so deletions drop out.
 * - Incremental (`dirtyPaths` a Set, from an fs watcher): only the dirty paths
 *   are stat'ed/re-read; every other cached entry is reused with ZERO
 *   syscalls. This remains available to focused callers and tests; production
 *   uses the structured scan so it never installs a recursive home watcher.
 */
export async function detectClaudeSessions(root, now, readyAfter, staleAfter, parents = null, cache = new Map(), dirtyPaths = null) {
  const states = {};
  const scanned = new Map();
  let sawRoot = false;

  const inspect = async (path) => {
    let metadata;
    try {
      metadata = await stat(path, { bigint: true });
    } catch {
      return null;
    }
    const modified = Number(metadata.mtimeNs) / 1e9;
    if (now - modified > staleAfter) return null;
    const fingerprint = [
      metadata.dev, metadata.ino, metadata.mtimeNs, metadata.ctimeNs, metadata.size
    ].join(":");
    const cached = cache.get(path);
    const stem = path.split("/").pop().replace(/\.jsonl$/, "");
    // First sight of this path (a new transcript, or every transcript after a
    // monitor restart) pays one full pass to recover links; later re-reads
    // stay on the cheap recent-record budget.
    const signal = cached && cached.fingerprint === fingerprint
      ? cached.signal
      : await claudeTranscriptSignal(path, modified, stem, { collectAllLinks: !cached });
    return { fingerprint, signal, modified };
  };

  if (dirtyPaths) {
    // Unchanged entries carry over untouched; only dirty ones hit the disk.
    for (const [path, entry] of cache) {
      if (dirtyPaths.has(path)) continue;
      if (now - (entry.modified ?? 0) > staleAfter) continue;
      scanned.set(path, entry);
    }
    for (const path of dirtyPaths) {
      if (!path.endsWith(".jsonl")) continue;
      const entry = await inspect(path);
      if (entry) scanned.set(path, entry);
      // A failed stat means deleted: simply not carrying it forward drops it.
    }
    sawRoot = true;
  } else {
    for await (const path of transcriptPaths(root)) {
      sawRoot = true;
      const entry = await inspect(path);
      if (entry) scanned.set(path, entry);
    }
  }

  for (const [path, entry] of scanned) {
    const signal = entry.signal;
    if (!signal) continue;
    if (parents) {
      for (const [provider, acpSession] of signal.links) {
        // A session cannot be its own parent.
        if (acpSession === signal.session) continue;
        const key = linkKey(provider, acpSession);
        if (parents.get(key)?.[0] !== signal.session) parents.set(key, [signal.session, signal.time]);
      }
    }
    // A tool still running (a build, a test run, a pending permission prompt)
    // writes nothing until it returns; that silence is not the session ending.
    // A turn that went silent without an end marker (a crash, a closed
    // terminal) is not still running; it is kept as idle like a finished one.
    let state = signal.state;
    let event = signal.event;
    if (state === "running" && event !== "tool_use" && now - signal.time > RUNNING_LIFETIME_SECONDS) {
      state = "ready";
      event = "silent";
    }
    const lifetime = state === "ready" ? readyAfter : staleAfter;
    if (now - signal.time <= lifetime) {
      states[signal.session] = {
        provider: "claude",
        session: signal.session,
        state,
        event,
        time: signal.time,
        pid: null,
        parent: signal.parent ?? externalParent(parents ?? new Map(), "claude", signal.session),
        engine: "claude-cli",
        cwd: signal.cwd,
        link_session: signal.session,
        transcript: path,
        agent_id: signal.parent ? signal.session : null
      };
    }
  }

  cache.clear();
  if (sawRoot) for (const [path, value] of scanned) cache.set(path, value);
  return states;
}
