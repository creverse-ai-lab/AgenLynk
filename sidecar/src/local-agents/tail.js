// Incremental JSONL tail with a bounded record window.
//
// The same byte-cursor rules as the Codex tailer (codex.js): advance only past
// complete lines, count in bytes (transcripts are full of multibyte text),
// adopt a large existing file from its tail, and start over when the file
// shrinks or is atomically replaced with same-sized content.

import { open, stat } from "node:fs/promises";
import { epochMs } from "../normalize/model.js";
import { readRecord, recordSize, slimRecord } from "./jsonl.js";

const DEFAULT_ADOPTION_TAIL_BYTES = 8 * 1024 * 1024;
const DEFAULT_MAX_RECORDS = 4_000;
const DEFAULT_WINDOW_MS = 65 * 60 * 1000;
// Retained window size (UTF-16 units of the kept records), whatever the
// record count: records are slimmed, but a window of 4,000 near-limit
// records would still be large.
export const DEFAULT_MAX_WINDOW_CHARS = 32 * 1024 * 1024;
// One poll never reads more than this; a burst past it is finished next poll.
export const MAX_READ_BYTES = 16 * 1024 * 1024;

export class RecordTail {
  /**
   * @param {string} path
   * @param {{
   *   keep?: (record: object) => boolean,
   *   onRecord?: (record: object) => void,
   *   timeOf?: (record: object) => number|null,
   *   maxRecords?: number,
   *   windowMs?: number,
   *   maxChars?: number,
   *   adoptionTailBytes?: number
   * }} options
   */
  constructor(path, options = {}) {
    this.path = path;
    this.keep = options.keep ?? (() => true);
    this.onRecord = options.onRecord ?? null;
    this.timeOf = options.timeOf ?? defaultTimeOf;
    this.maxRecords = options.maxRecords ?? DEFAULT_MAX_RECORDS;
    this.windowMs = options.windowMs ?? DEFAULT_WINDOW_MS;
    this.maxChars = options.maxChars ?? DEFAULT_MAX_WINDOW_CHARS;
    this.adoptionTailBytes = options.adoptionTailBytes ?? DEFAULT_ADOPTION_TAIL_BYTES;
    this.offset = 0;
    this.lastMtimeMs = 0;
    this.records = [];
    // Retained size per record (parallel to `records`) and their sum.
    this.sizes = [];
    this.chars = 0;
    // True when the first read skipped the head of the file: cumulative facts
    // (Claude token totals) then cover only what was read.
    this.adoptedFromTail = false;
    this.missing = false;
  }

  /** Reads appended lines. Returns true when the window changed. */
  async poll(nowMs = Date.now()) {
    let metadata;
    try {
      metadata = await stat(this.path);
    } catch {
      this.missing = true;
      return false;
    }
    this.missing = false;
    if (metadata.size < this.offset
      || (metadata.size === this.offset && this.offset > 0 && metadata.mtimeMs !== this.lastMtimeMs)) {
      this.offset = 0;
      this.records = [];
      this.sizes = [];
      this.chars = 0;
      this.adoptedFromTail = false;
    }
    if (metadata.size === this.offset) return this.#prune(nowMs);

    const initial = this.offset === 0;
    if (initial && metadata.size > this.adoptionTailBytes) {
      this.offset = metadata.size - this.adoptionTailBytes;
      this.adoptedFromTail = true;
    }
    const length = Math.min(metadata.size - this.offset, MAX_READ_BYTES);
    const buffer = Buffer.alloc(length);
    let handle;
    let bytesRead = 0;
    try {
      handle = await open(this.path, "r");
      ({ bytesRead } = await handle.read(buffer, 0, length, this.offset));
    } catch {
      return false;
    } finally {
      await handle?.close().catch(() => {});
    }
    let skip = 0;
    if (initial && this.offset > 0) {
      const firstNewline = buffer.indexOf(0x0A);
      skip = firstNewline >= 0 ? firstNewline + 1 : bytesRead;
    }
    const view = buffer.subarray(skip, bytesRead);
    const lastNewline = view.lastIndexOf(0x0A);
    const consumed = lastNewline >= 0 ? lastNewline + 1 : 0;
    let changed = false;
    for (const line of view.subarray(0, consumed).toString("utf8").split("\n")) {
      if (!line) continue;
      const record = readRecord(line);
      if (!record || typeof record !== "object") continue;
      this.onRecord?.(record);
      if (!this.keep(record)) continue;
      const kept = slimRecord(record);
      const size = recordSize(line, record, kept);
      this.records.push(kept);
      this.sizes.push(size);
      this.chars += size;
      changed = true;
    }
    // A single line longer than one read would otherwise pin the cursor
    // forever; drop the oversized chunk and resynchronize on the next line.
    this.offset += consumed === 0 && length === MAX_READ_BYTES ? bytesRead : skip + consumed;
    // A partial last line is re-read next poll; only a complete read pins the
    // mtime used for same-size rewrite detection.
    if (this.offset >= metadata.size) this.lastMtimeMs = metadata.mtimeMs;
    return this.#prune(nowMs) || changed;
  }

  #prune(nowMs) {
    const cutoff = nowMs - this.windowMs;
    let drop = 0;
    while (drop < this.records.length) {
      const at = this.timeOf(this.records[drop]);
      if (at == null || at >= cutoff) break;
      drop += 1;
    }
    if (this.records.length - drop > this.maxRecords) drop = this.records.length - this.maxRecords;
    let chars = this.chars;
    for (let index = 0; index < drop; index += 1) chars -= this.sizes[index];
    // The newest record always stays, however large.
    while (chars > this.maxChars && drop < this.records.length - 1) {
      chars -= this.sizes[drop];
      drop += 1;
    }
    if (drop > 0) {
      this.records.splice(0, drop);
      this.sizes.splice(0, drop);
      this.chars = chars;
    }
    return drop > 0;
  }
}

function defaultTimeOf(record) {
  return epochMs(record?.timestamp);
}
