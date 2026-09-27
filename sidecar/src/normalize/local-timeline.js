// Per-session timelines for local CLI sessions, one pipeline for all three
// providers: the scanner (../local-agents) decides which sessions exist and
// where their transcript is; this module tails that transcript, runs the
// provider's normalizer over the retained window, and hands back canonical
// events plus session facts (model, usage, status, title).

import { readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { RecordTail } from "../local-agents/tail.js";
import { normalizeGrokUpdates, grokUsage } from "./acp.js";
import { ClaudeUsageAccumulator, inScope as claudeInScope, normalizeClaudeRecords } from "./claude.js";
import { normalizeCodexRecords } from "./codex.js";
import { overlayUsage } from "./model.js";

// A session that leaves the scan (a Claude turn that went quiet) keeps its
// tail this long, so coming back costs an incremental read, not a re-adoption.
const ENTRY_TTL_MS = 10 * 60 * 1000;

const CLAUDE_KEPT_TYPES = new Set(["user", "assistant", "system", "ai-title"]);

function keepGrokRecord(record) {
  const update = record?.params?.update;
  if (!update) return false;
  // Hook bookkeeping is most of the file; only the prompt id it carries matters.
  if (update.sessionUpdate === "hook_execution") return update.event_name === "user_prompt_submit";
  return true;
}

async function readJsonIfChanged(path, previous) {
  let metadata;
  try {
    metadata = await stat(path);
  } catch {
    return { mtimeMs: 0, value: null, changed: previous?.mtimeMs !== 0 && previous != null };
  }
  if (previous && previous.mtimeMs === metadata.mtimeMs) return { ...previous, changed: false };
  try {
    return { mtimeMs: metadata.mtimeMs, value: JSON.parse(await readFile(path, "utf8")), changed: true };
  } catch {
    return { mtimeMs: metadata.mtimeMs, value: previous?.value ?? null, changed: false };
  }
}

export class LocalTimeline {
  /**
   * @param {{ codexRecords?: (rawSessionId: string) => object[], windowMs?: number, maxRecords?: number }} options
   * Codex windows come from the scanner's own tail (codex.js keeps them), so
   * the rollout is read once for both state and timeline. `windowMs` and
   * `maxRecords` bound the Claude and Grok windows the same way (the
   * localTranscriptWindowMs / localTranscriptRecordLimit settings).
   */
  constructor({ codexRecords = () => [], windowMs = undefined, maxRecords = undefined } = {}) {
    this.codexRecords = codexRecords;
    this.tailOptions = {
      ...(windowMs != null ? { windowMs } : {}),
      ...(maxRecords != null ? { maxRecords } : {})
    };
    this.entries = new Map();
  }

  /**
   * @param {object[]} rawSessions scanner records ({provider, session, transcript, agent_id, ...})
   * @returns {Promise<{ results: Map<string, {events, session}>, changed: Set<string> }>}
   *   keyed by `${provider}:${session}`
   */
  async update(rawSessions, nowMs = Date.now()) {
    const results = new Map();
    const changed = new Set();
    const seen = new Set();
    for (const raw of Array.isArray(rawSessions) ? rawSessions : []) {
      const key = `${raw?.provider}:${raw?.session}`;
      if (!raw?.session || seen.has(key)) continue;
      seen.add(key);
      const entry = this.#entry(key, raw);
      if (!entry) continue;
      entry.lastSeen = nowMs;
      if (await this.#refresh(entry, raw, nowMs)) changed.add(key);
      if (entry.result) results.set(key, entry.result);
    }
    for (const [key, entry] of this.entries) {
      if (!seen.has(key) && nowMs - entry.lastSeen > ENTRY_TTL_MS) this.entries.delete(key);
    }
    return { results, changed };
  }

  #entry(key, raw) {
    const existing = this.entries.get(key);
    const source = raw.provider === "codex" ? "codex-window" : raw.transcript ?? null;
    if (existing && existing.source === source) return existing;
    let entry = null;
    if (raw.provider === "codex") {
      entry = { provider: "codex", source, signature: null };
    } else if (raw.provider === "claude" && raw.transcript) {
      const agentId = raw.agent_id ?? null;
      const usage = new ClaudeUsageAccumulator();
      entry = {
        provider: "claude",
        source,
        agentId,
        usage,
        tail: new RecordTail(raw.transcript, {
          ...this.tailOptions,
          keep: (record) => CLAUDE_KEPT_TYPES.has(record?.type),
          onRecord: (record) => {
            if (claudeInScope(record, agentId)) usage.add(record);
          }
        })
      };
    } else if (raw.provider === "grok" && raw.transcript) {
      entry = {
        provider: "grok",
        source,
        directory: raw.transcript,
        usageFile: null,
        signalsFile: null,
        summaryFile: null,
        tail: new RecordTail(join(raw.transcript, "updates.jsonl"), { ...this.tailOptions, keep: keepGrokRecord })
      };
    }
    if (entry) this.entries.set(key, { ...entry, result: null, lastSeen: 0 });
    return this.entries.get(key) ?? null;
  }

  async #refresh(entry, raw, nowMs) {
    if (entry.provider === "codex") {
      const records = this.codexRecords(raw.session) ?? [];
      const last = records.at(-1);
      const signature = `${records.length}:${last?.timestamp ?? ""}:${last?.ordinal ?? ""}:${last?.payload?.type ?? ""}`;
      if (signature === entry.signature && entry.result) return false;
      entry.signature = signature;
      entry.result = normalizeCodexRecords(records);
      return true;
    }
    if (entry.provider === "claude") {
      const tailChanged = await entry.tail.poll(nowMs);
      if (!tailChanged && entry.result) return false;
      const result = normalizeClaudeRecords(entry.tail.records, { agentId: entry.agentId });
      result.session.usage = overlayUsage(result.session.usage, entry.usage.totals());
      if (entry.tail.adoptedFromTail && result.session.usage) result.session.usagePartial = true;
      entry.result = result;
      return true;
    }
    if (entry.provider === "grok") {
      const tailChanged = await entry.tail.poll(nowMs);
      entry.usageFile = await readJsonIfChanged(join(entry.directory, "usage.json"), entry.usageFile);
      entry.signalsFile = await readJsonIfChanged(join(entry.directory, "signals.json"), entry.signalsFile);
      entry.summaryFile = await readJsonIfChanged(join(entry.directory, "summary.json"), entry.summaryFile);
      if (!tailChanged && !entry.usageFile.changed && !entry.signalsFile.changed && !entry.summaryFile.changed && entry.result) {
        return false;
      }
      const result = normalizeGrokUpdates(entry.tail.records);
      const files = grokUsage(entry.usageFile.value, entry.signalsFile.value);
      result.session.usage = overlayUsage(result.session.usage, files.usage);
      if (!result.session.model && files.model) result.session.model = files.model;
      // Grok names a one-shot run (`grok -p`) itself. The process lineage
      // cannot always tell: a hook's shell has usually exited by the time the
      // process table is read, and a short run is gone before a process scan.
      if (entry.summaryFile.value?.session_kind === "headless") result.session.headless = true;
      delete result.session.lastTurnUsage;
      entry.result = result;
      return true;
    }
    return false;
  }
}
